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

    node.cluster.join(endpoint: node.cluster.endpoint)
    try await node.cluster.joined(within: .seconds(3))

    let messages = ["hello", "test", "recovery"]
    var actor: TestActor?
    for i in 0..<2 {
      actor = try await TestActor(actorSystem: node)
      try await actor?.send(message: messages[0])
      actor = .none
      actor = try await TestActor(actorSystem: node)
      try await actor?.send(message: messages[1])
      try await actor?.send(message: messages[2])
      let actorMessages = try await actor?.getMessages() ?? []
      #expect(actorMessages == messages, "Expected \(messages), but got \(actorMessages), iteration: \(i)")
      await store.flush()
    }
  }

  @Test
  func test_snapshot_restore() async throws {
    let store = MemoryEventStore()
    let snapshotStore = MemorySnapshotStore()
    let node = await ClusterSystem("snapshot-node") {
      $0.bindPort = 7340
      $0.plugins.install(plugin: ClusterSingletonPlugin())
      $0.plugins.install(
        plugin: ClusterJournalPlugin(
          factory: { _ in store },
          snapshotFactory: { _ in snapshotStore }
        )
      )

      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)

      $0.swim.lifeguard.maxLocalHealthMultiplier = 2
      $0.swim.lifeguard.suspicionTimeoutMin = .milliseconds(500)
      $0.swim.lifeguard.suspicionTimeoutMax = .seconds(1)
    }

    node.cluster.join(endpoint: node.cluster.endpoint)
    try await node.cluster.joined(within: .seconds(3))

    let messages = ["one", "two", "three"]

    var actor: TestActor? = try await TestActor(
      actorSystem: node,
      with: "snapshot-actor",
      snapshotting: .enabled(every: 2)
    )
    for message in messages {
      try await actor?.send(message: message)
    }

    // Snapshot at seq 2 (state ["one", "two"]) must have been saved exactly once.
    let covered = await snapshotStore.coveredSequenceNumber(for: "snapshot-actor")
    #expect(covered == 2, "Expected snapshot covering seq 2, got \(String(describing: covered))")
    actor = .none

    // Restore: phase 1 assigns the snapshot (state ["one", "two"], seq 2),
    // phase 2 folds only the suffix (["three"]) — full history never folded.
    actor = try await TestActor(
      actorSystem: node,
      with: "snapshot-actor",
      snapshotting: .enabled(every: 2)
    )
    let restored = try await actor?.getMessages() ?? []
    #expect(restored == messages, "Expected \(messages) after snapshot restore, got \(restored)")
    let sequenceNumber = try await actor?.getSequenceNumber() ?? 0
    #expect(sequenceNumber == 3, "Expected sequence number 3 after snapshot restore, got \(sequenceNumber)")
    actor = .none
  }

  @Test
  func test_snapshotting_without_snapshot_store() async throws {
    let store = MemoryEventStore()
    let node = await ClusterSystem("no-snapshot-store-node") {
      $0.bindPort = 7341
      $0.plugins.install(plugin: ClusterSingletonPlugin())
      $0.plugins.install(
        plugin: ClusterJournalPlugin { _ in
          store
        }
      )

      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)

      $0.swim.lifeguard.maxLocalHealthMultiplier = 2
      $0.swim.lifeguard.suspicionTimeoutMin = .milliseconds(500)
      $0.swim.lifeguard.suspicionTimeoutMax = .seconds(1)
    }

    node.cluster.join(endpoint: node.cluster.endpoint)
    try await node.cluster.joined(within: .seconds(3))

    // Snapshotting enabled but no snapshot store configured: saves fail with
    // SnapshottingError.storeNotConfigured, which emit demotes to a log
    // warning — journaling itself must be unaffected.
    let messages = ["one", "two", "three"]
    var actor: TestActor? = try await TestActor(
      actorSystem: node,
      with: "no-snapshot-store-actor",
      snapshotting: .enabled(every: 2)
    )
    for message in messages {
      try await actor?.send(message: message)
    }
    let live = try await actor?.getMessages() ?? []
    #expect(live == messages, "Expected \(messages), got \(live)")
    actor = .none

    // No snapshot was ever saved, so recovery is a full replay.
    actor = try await TestActor(
      actorSystem: node,
      with: "no-snapshot-store-actor",
      snapshotting: .enabled(every: 2)
    )
    let restored = try await actor?.getMessages() ?? []
    #expect(restored == messages, "Expected \(messages) after full replay, got \(restored)")
    let sequenceNumber = try await actor?.getSequenceNumber() ?? 0
    #expect(sequenceNumber == 3, "Expected sequence number 3 after full replay, got \(sequenceNumber)")
    actor = .none
  }

  @Test
  func test_cancelled_restore_throws() async throws {
    let store = MemoryEventStore()
    let node = await ClusterSystem("cancel-node") {
      $0.bindPort = 7342
      $0.plugins.install(plugin: ClusterSingletonPlugin())
      $0.plugins.install(
        plugin: ClusterJournalPlugin { _ in
          store
        }
      )

      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)

      $0.swim.lifeguard.maxLocalHealthMultiplier = 2
      $0.swim.lifeguard.suspicionTimeoutMin = .milliseconds(500)
      $0.swim.lifeguard.suspicionTimeoutMax = .seconds(1)
    }

    node.cluster.join(endpoint: node.cluster.endpoint)
    try await node.cluster.joined(within: .seconds(3))

    // Seed the journal so a cancelled restore actually has events to fold.
    var actor: TestActor? = try await TestActor(actorSystem: node, with: "cancelled-actor")
    try await actor?.send(message: "one")
    try await actor?.send(message: "two")
    actor = .none

    // A cancelled activation must fail loudly — never come up registered on
    // partially-restored state.
    let task = Task {
      try await TestActor(actorSystem: node, with: "cancelled-actor")
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }

  @EventSourced
  distributed actor TestActor {

    struct State: Codable, Sendable {
      var messages: [String] = []
    }

    enum Event: Codable, Sendable {
      case message(String)
    }

    var state: State = .init()

    let snapshotting: Snapshotting

    distributed func send(message: String) async throws {
      try await self.emit(event: .message(message))
    }

    distributed func getMessages() -> [String] {
      self.state.messages
    }

    distributed func getSequenceNumber() -> Int64 {
      self.sequenceNumber
    }

    distributed func handleEvent(_ event: Event) {
      switch event {
      case .message(let string):
        self.actorSystem.log.debug("Handle \(event)")
        self.state.messages.append(string)
      }
    }

    init(
      actorSystem: ClusterSystem,
      with persistenceId: String = "test-actor",
      snapshotting: Snapshotting = .disabled
    ) async throws {
      self.actorSystem = actorSystem
      self.snapshotting = snapshotting
      try await actorSystem
        .journal
        .register(actor: self, with: persistenceId)
    }
  }
}

actor MemoryEventStore: EventStore, Sendable {

  private var dict: [PersistenceID: [Data]] = [:]
  private let encoder: JSONEncoder = JSONEncoder()
  private let decoder: JSONDecoder = JSONDecoder()

  func persistEvent<Event: Codable & Sendable>(_ event: Event, id: PersistenceID, sequenceNumber: Int64) throws {
    let data = try encoder.encode(event)
    self.dict[id, default: []].append(data)
  }

  func eventsFor<Event: Codable & Sendable>(id: PersistenceID, fromSequenceNumber: Int64) throws -> [Event] {
    let events = self.dict[id] ?? []
    let drop = Int(fromSequenceNumber - 1)
    guard drop < events.count else { return [] }
    return events.dropFirst(drop).compactMap { try? self.decoder.decode(Event.self, from: $0) }
  }

  func flush() {
    self.dict.removeAll()
  }

  init() {}
}

actor MemorySnapshotStore: SnapshotStore, Sendable {

  private var dict: [PersistenceID: (data: Data, covered: Int64)] = [:]
  private let encoder: JSONEncoder = JSONEncoder()
  private let decoder: JSONDecoder = JSONDecoder()

  func save<State: Codable & Sendable>(_ state: State, id: PersistenceID, coveredSequenceNumber: Int64) throws {
    // Monotonic per the SnapshotStore contract: keep the highest covered.
    guard coveredSequenceNumber > (self.dict[id]?.covered ?? 0) else { return }
    self.dict[id] = (try encoder.encode(state), coveredSequenceNumber)
  }

  func latestSnapshot<State: Codable & Sendable>(id: PersistenceID) throws -> Snapshot<State>? {
    guard let entry = self.dict[id],
      let state = try? self.decoder.decode(State.self, from: entry.data)
    else { return nil }
    return Snapshot(state: state, coveredSequenceNumber: entry.covered)
  }

  func coveredSequenceNumber(for id: PersistenceID) -> Int64? {
    self.dict[id]?.covered
  }

  init() {}
}
