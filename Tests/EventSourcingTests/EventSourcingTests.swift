import Foundation
import Testing

@testable import DistributedCluster
@testable import EventSourcing

typealias DefaultDistributedActorSystem = ClusterSystem

struct EventSourcingTests {

  @Test
  func test_simple_actor() async throws {
    let store = MemoryEventStore()
    let node = await ClusterSystem("simple-node") {
      $0.plugins.install(plugin: ClusterSingletonPlugin())
      $0.plugins.install(
        plugin: ClusterJournalPlugin { _ in
          store
        }
      )

      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)

      // Make suspicion propagation faster
      $0.swim.lifeguard.maxLocalHealthMultiplier = 2
      $0.swim.lifeguard.suspicionTimeoutMin = .milliseconds(500)
      $0.swim.lifeguard.suspicionTimeoutMax = .seconds(1)
    }
    let messages = ["hello", "test", "recovery"]
    var actor: TestActor?
    for i in 0..<2 {
      actor = await TestActor(actorSystem: node)
      try await actor?.send(message: messages[0])
      actor = .none
      actor = await TestActor(actorSystem: node)
      try await Task.sleep(for: .seconds(3))  // FIXME: Currently there is no guarantee in the system that actor will be restored properly
      try await actor?.send(message: messages[1])
      try await actor?.send(message: messages[2])
      let actorMessages = try await actor?.getMessages() ?? []
      #expect(actorMessages == messages, "Expected \(messages), but got \(actorMessages), iteration: \(i)")
      await store.flush()
    }
  }

  distributed actor TestActor: EventSourced {

    struct State {
      var messages: [String] = []
    }

    enum Event: Codable, Sendable {
      case message(String)
    }

    distributed var persistenceID: PersistenceID {
      _persistenceID
    }

    private var _persistenceID: PersistenceID

    var state: State = .init()

    distributed func send(message: String) async throws {
      try await self.emit(event: .message(message))
    }

    distributed func getMessages() -> [String] {
      self.state.messages
    }

    distributed func handleEvent(_ event: Event) {
      switch event {
      case .message(let string):
        self.actorSystem.log.debug(.init(stringLiteral: string))
        self.state.messages.append(string)
      }
    }

    init(actorSystem: ClusterSystem) async {
      self.actorSystem = actorSystem
      self._persistenceID = "test-actor"
    }
  }
}

actor MemoryEventStore: EventStore, Sendable {

  private var dict: [PersistenceID: [Data]] = [:]
  private let encoder: JSONEncoder = JSONEncoder()
  private let decoder: JSONDecoder = JSONDecoder()

  func persistEvent<Event: Codable & Sendable>(_ event: Event, id: PersistenceID) throws {
    let data = try encoder.encode(event)
    self.dict[id, default: []].append(data)
  }

  func eventsFor<Event: Codable & Sendable>(id: PersistenceID) throws -> [Event] {
    self.dict[id]?.compactMap(decoder.decode) ?? []
  }

  func flush() { self.dict.removeAll() }

  init(
    dict: [String: [Data]] = [:]
  ) {
    self.dict = dict
  }
}

extension JSONDecoder {
  fileprivate func decode<T: Decodable>(_ data: Data) -> T? {
    try? self.decode(T.self, from: data)
  }
}
