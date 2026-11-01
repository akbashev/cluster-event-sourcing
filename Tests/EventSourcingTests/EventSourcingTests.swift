import Foundation
import Testing

@testable import DistributedCluster
@testable import EventSourcing

typealias DefaultDistributedActorSystem = ClusterSystem

struct EventSourcingTests {

  @Test
  func test_snapshot_selection_criteria_uses_inclusive_bounds() {
    let criteria = SnapshotSelectionCriteria(
      minSequenceNumber: 2,
      maxSequenceNumber: 4
    )

    #expect(!criteria.includes(1))
    #expect(criteria.includes(2))
    #expect(criteria.includes(4))
    #expect(!criteria.includes(5))
  }

  @Test
  func test_event_stream_only_produces_on_pull() async throws {
    let source = PullSource([1, 2])
    let stream = AsyncThrowingStream<EventEnvelope<Int>, any Error>(unfolding: {
      await source.next().map {
        EventEnvelope(persistenceID: "stream", sequenceNumber: Int64($0), offset: Offset(Int64($0)), event: $0)
      }
    })
    #expect(await source.pullCount == 0)

    var iterator = stream.makeAsyncIterator()
    let first = try await iterator.next()
    #expect(await source.pullCount == 1)
    let second = try await iterator.next()
    #expect(await source.pullCount == 2)
    let end = try await iterator.next()
    #expect(await source.pullCount == 3)

    #expect(first?.event == 1)
    #expect(second?.event == 2)
    #expect(end == nil)
  }

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
      snapshotting: .every(numberOfEvents: 2, retention: .keepLast(2))
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
      snapshotting: .every(numberOfEvents: 2, retention: .keepLast(2))
    )
    let restored = try await actor?.getMessages() ?? []
    #expect(restored == messages, "Expected \(messages) after snapshot restore, got \(restored)")
    let sequenceNumber = try await actor?.getSequenceNumber() ?? 0
    #expect(sequenceNumber == 3, "Expected sequence number 3 after snapshot restore, got \(sequenceNumber)")
    actor = .none
  }

  @Test
  func test_recovery_streams_events_through_receiver() async throws {
    let store = MemoryEventStore()
    let node = await ClusterSystem("streamed-recovery-node") {
      $0.bindPort = 7345
      $0.plugins.install(plugin: ClusterSingletonPlugin())
      $0.plugins.install(plugin: ClusterJournalPlugin { _ in store })
      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
    }

    node.cluster.join(endpoint: node.cluster.endpoint)
    try await node.cluster.joined(within: .seconds(3))

    var actor: TestActor? = try await TestActor(actorSystem: node, with: "streamed-recovery-actor")
    for number in 1...257 {
      try await actor?.send(message: String(number))
    }
    actor = .none

    let requestsBeforeRecovery = await store.eventStreamRequestCount(for: "streamed-recovery-actor")
    actor = try await TestActor(actorSystem: node, with: "streamed-recovery-actor")

    let restored = try await actor?.getMessages() ?? []
    let requestsAfterRecovery = await store.eventStreamRequestCount(for: "streamed-recovery-actor")
    #expect(restored.count == 257)
    #expect(restored.first == "1")
    #expect(restored.last == "257")
    #expect(requestsAfterRecovery - requestsBeforeRecovery == 1)
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
      snapshotting: .every(numberOfEvents: 2, retention: .keepLast(2))
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
      snapshotting: .every(numberOfEvents: 2, retention: .keepLast(2))
    )
    let restored = try await actor?.getMessages() ?? []
    #expect(restored == messages, "Expected \(messages) after full replay, got \(restored)")
    let sequenceNumber = try await actor?.getSequenceNumber() ?? 0
    #expect(sequenceNumber == 3, "Expected sequence number 3 after full replay, got \(sequenceNumber)")
    actor = .none
  }

  @Test
  func test_snapshotting_rule() async throws {
    let store = MemoryEventStore()
    let snapshotStore = MemorySnapshotStore()
    let node = await ClusterSystem("snapshot-rule-node") {
      $0.bindPort = 7343
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

    // The rule fires only on the "milestone" message: snapshots land at
    // domain-meaningful events, not on a fixed cadence.
    var actor: TestActor? = try await TestActor(
      actorSystem: node,
      with: "snapshot-rule-actor",
      snapshotting: .when { event, _, _ in
        if case .message("milestone") = event { return true }
        return false
      }
    )
    try await actor?.send(message: "one")
    // No snapshot yet: the rule did not fire.
    var covered = await snapshotStore.coveredSequenceNumber(for: "snapshot-rule-actor")
    #expect(covered == nil, "Expected no snapshot before the rule fires, got \(String(describing: covered))")

    try await actor?.send(message: "milestone")
    // Snapshot at seq 2 (state ["one", "milestone"]) saved by the rule.
    covered = await snapshotStore.coveredSequenceNumber(for: "snapshot-rule-actor")
    #expect(covered == 2, "Expected snapshot covering seq 2, got \(String(describing: covered))")

    try await actor?.send(message: "three")
    // Still seq 2: later events don't re-trigger the rule.
    covered = await snapshotStore.coveredSequenceNumber(for: "snapshot-rule-actor")
    #expect(covered == 2, "Expected snapshot still covering seq 2, got \(String(describing: covered))")
    actor = .none

    // Restore: snapshot at seq 2 + tail fold of ["three"].
    actor = try await TestActor(
      actorSystem: node,
      with: "snapshot-rule-actor",
      snapshotting: .disabled
    )
    let restored = try await actor?.getMessages() ?? []
    #expect(restored == ["one", "milestone", "three"], "Got \(restored)")
    actor = .none

    // Predicate-triggered snapshots do not run periodic retention. This
    // matches Akka's snapshotWhen behavior: all three matching snapshots stay.
    actor = try await TestActor(
      actorSystem: node,
      with: "snapshot-rule-retention-actor",
      snapshotting: .when { event, _, _ in
        if case .message("milestone") = event { return true }
        return false
      }
    )
    try await actor?.send(message: "milestone")
    try await actor?.send(message: "between")
    try await actor?.send(message: "milestone")
    try await actor?.send(message: "milestone")
    let ruleSnapshots = await snapshotStore.coveredSequenceNumbers(for: "snapshot-rule-retention-actor")
    #expect(ruleSnapshots == [1, 3, 4], "Expected all rule snapshots, got \(ruleSnapshots)")
    actor = .none

    // Rule snapshots are supplemental. The periodic snapshot at seq 6 deletes
    // through seq 3, retaining the newest cadence window plus the rule snapshot
    // at seq 4; the rule snapshot itself does not initiate cleanup.
    actor = try await TestActor(
      actorSystem: node,
      with: "snapshot-or-when-actor",
      snapshotting: .every(
        numberOfEvents: 3,
        retention: .keepLast(1),
        orWhen: { event, _, _ in
          if case .message("milestone") = event { return true }
          return false
        }
      )
    )
    try await actor?.send(message: "one")
    try await actor?.send(message: "milestone")
    try await actor?.send(message: "three")
    try await actor?.send(message: "milestone")
    try await actor?.send(message: "five")
    try await actor?.send(message: "six")
    let combinedSnapshots = await snapshotStore.coveredSequenceNumbers(for: "snapshot-or-when-actor")
    #expect(combinedSnapshots == [4, 6], "Expected cadence-window snapshots, got \(combinedSnapshots)")
    actor = .none
  }

  @Test
  func test_periodic_snapshot_retention() async throws {
    let store = MemoryEventStore()
    let snapshotStore = MemorySnapshotStore()
    let node = await ClusterSystem("snapshot-retention-node") {
      $0.bindPort = 7344
      $0.plugins.install(plugin: ClusterSingletonPlugin())
      $0.plugins.install(
        plugin: ClusterJournalPlugin(
          factory: { _ in store },
          snapshotFactory: { _ in snapshotStore }
        )
      )
      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
    }

    node.cluster.join(endpoint: node.cluster.endpoint)
    try await node.cluster.joined(within: .seconds(3))

    var actor: TestActor? = try await TestActor(
      actorSystem: node,
      with: "snapshot-retention-actor",
      snapshotting: .every(numberOfEvents: 2, retention: .keepLast(2))
    )
    for message in ["one", "two", "three", "four", "five", "six"] {
      try await actor?.send(message: message)
    }

    let retained = await snapshotStore.coveredSequenceNumbers(for: "snapshot-retention-actor")
    #expect(retained == [4, 6], "Expected the newest two snapshots, got \(retained)")
    actor = .none

    actor = try await TestActor(
      actorSystem: node,
      with: "snapshot-keep-all-actor",
      snapshotting: .every(numberOfEvents: 2)
    )
    for message in ["one", "two", "three", "four", "five", "six"] {
      try await actor?.send(message: message)
    }

    let allSnapshots = await snapshotStore.coveredSequenceNumbers(for: "snapshot-keep-all-actor")
    #expect(allSnapshots == [2, 4, 6], "Expected every snapshot to be retained, got \(allSnapshots)")
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

  @Test
  func test_events_are_kept_with_their_entity_tags() async throws {
    let store = MemoryEventStore()
    let node = await ClusterSystem("tagging-node") {
      $0.bindPort = 7346
      $0.plugins.install(plugin: ClusterSingletonPlugin())
      $0.plugins.install(plugin: ClusterJournalPlugin { _ in store })
      $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
    }

    node.cluster.join(endpoint: node.cluster.endpoint)
    try await node.cluster.joined(within: .seconds(3))

    let tag = EventTag("test")
    var first: TestActor? = try await TestActor(actorSystem: node, with: "tagged-first", tagging: .always(tag))
    var second: TestActor? = try await TestActor(actorSystem: node, with: "tagged-second", tagging: .always(tag))
    var untagged: TestActor? = try await TestActor(actorSystem: node, with: "untagged")
    try await first?.send(message: "one")
    try await untagged?.send(message: "none")
    try await second?.send(message: "two")
    try await first?.send(message: "three")
    first = .none
    second = .none
    untagged = .none

    // Every entity's tagged events, in the order they were kept; none of the
    // untagged entity's.
    let tagged = try await Self.read(tag, after: .start, in: store)
    #expect(tagged.map(\.event) == [.message("one"), .message("two"), .message("three")])
    #expect(tagged.map(\.persistenceID) == ["tagged-first", "tagged-second", "tagged-first"])
    #expect(tagged.map(\.sequenceNumber) == [1, 1, 2])
    #expect(tagged.map(\.offset) == tagged.map(\.offset).sorted())

    // Reading after an offset reads only what was kept after it.
    let rest = try await Self.read(tag, after: tagged[0].offset, in: store)
    #expect(rest.map(\.event) == [.message("two"), .message("three")])
  }

  @Test
  func test_projection_follows_a_tag_from_its_offset() async throws {
    let store = MemoryEventStore()
    let tag = EventTag("projected")
    let readSide = ReadSide()
    func projection() -> Projection<String> {
      Projection(tag: tag, offset: { await readSide.offset }, process: { await readSide.keep($0) })
    }

    try await store.persistEvent("one", id: "a", sequenceNumber: 1, tags: [tag])
    try await store.persistEvent("other", id: "b", sequenceNumber: 1, tags: [])
    try await store.persistEvent("two", id: "b", sequenceNumber: 2, tags: [tag])

    // It catches up, then follows what's kept after it started.
    var running = Task { try await projection().run(on: store, refreshInterval: .milliseconds(10)) }
    try await readSide.waitFor(count: 2)
    try await store.persistEvent("three", id: "a", sequenceNumber: 2, tags: [tag])
    try await readSide.waitFor(count: 3)
    running.cancel()
    await #expect(throws: CancellationError.self) { try await running.value }
    #expect(await readSide.kept == ["one", "two", "three"])

    // Started again, it carries on from the offset it kept: nothing twice.
    try await store.persistEvent("four", id: "a", sequenceNumber: 3, tags: [tag])
    running = Task { try await projection().run(on: store, refreshInterval: .milliseconds(10)) }
    try await readSide.waitFor(count: 4)
    running.cancel()
    _ = try? await running.value
    #expect(await readSide.kept == ["one", "two", "three", "four"])
  }

  /// The test actors' events tagged `tag` after `offset`, read whole.
  private static func read(
    _ tag: EventTag,
    after offset: Offset,
    in store: MemoryEventStore
  ) async throws -> [EventEnvelope<TestActor.Event>] {
    let events: EventStream<TestActor.Event> = try await store.currentEventsByTag(tag, after: offset)
    var envelopes: [EventEnvelope<TestActor.Event>] = []
    for try await envelope in events {
      envelopes.append(envelope)
    }
    return envelopes
  }

  /// A read side for `test_projection_follows_a_tag_from_its_offset`: what it
  /// kept, and the offset of the last.
  private actor ReadSide {
    private(set) var kept: [String] = []
    private(set) var offset = Offset.start

    func keep(_ envelope: EventEnvelope<String>) {
      self.kept.append(envelope.event)
      self.offset = envelope.offset
    }

    /// Waits until it has kept `count` events, for a second at most.
    func waitFor(count: Int) async throws {
      for _ in 0..<100 where self.kept.count < count {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(self.kept.count >= count, "Kept \(self.kept) after a second")
    }
  }

  @EventSourced
  distributed actor TestActor {

    struct State: Codable, Sendable {
      var messages: [String] = []
    }

    enum Event: Codable, Sendable, Equatable {
      case message(String)
    }

    var state: State = .init()

    let snapshotting: Snapshotting<Event, State>

    let tagging: Tagging<Event>

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
      snapshotting: Snapshotting<Event, State> = .disabled,
      tagging: Tagging<Event> = .none
    ) async throws {
      self.actorSystem = actorSystem
      self.snapshotting = snapshotting
      self.tagging = tagging
      try await actorSystem
        .journal
        .register(actor: self, with: persistenceId)
    }
  }
}

actor MemoryEventStore: EventStore, Sendable {

  /// An event as kept: its offset is its place in `journal`, counting from 1.
  private struct Kept {
    let id: PersistenceID
    let sequenceNumber: Int64
    let tags: Set<EventTag>
    let data: Data
  }

  private var journal: [Kept] = []
  private var eventStreamRequests: [PersistenceID: Int] = [:]
  private let encoder: JSONEncoder = JSONEncoder()

  func persistEvent<Event: Codable & Sendable>(
    _ event: Event,
    id: PersistenceID,
    sequenceNumber: Int64,
    tags: Set<EventTag>
  ) throws {
    self.journal.append(Kept(id: id, sequenceNumber: sequenceNumber, tags: tags, data: try encoder.encode(event)))
  }

  func eventStream<Event: Codable & Sendable>(
    id: PersistenceID,
    fromSequenceNumber: Int64
  ) async throws -> EventStream<Event> {
    self.eventStreamRequests[id, default: 0] += 1
    return self.stream { kept, _ in kept.id == id && kept.sequenceNumber >= fromSequenceNumber }
  }

  func currentEventsByTag<Event: Codable & Sendable>(
    _ tag: EventTag,
    after offset: Offset
  ) async throws -> EventStream<Event> {
    self.stream { kept, keptAt in kept.tags.contains(tag) && keptAt > offset }
  }

  /// The events kept so far that `included` takes, read one at a time.
  private func stream<Event: Codable & Sendable>(
    of included: (Kept, Offset) -> Bool
  ) -> EventStream<Event> {
    let cursor = MemoryEventCursor<Event>(
      kept: self.journal.enumerated().compactMap { index, kept in
        let offset = Offset(Int64(index + 1))
        guard included(kept, offset) else { return nil }
        return (kept.id, kept.sequenceNumber, offset, kept.data)
      }
    )
    return AsyncThrowingStream(unfolding: {
      try await cursor.next()
    })
  }

  func flush() {
    self.journal.removeAll()
  }

  func eventStreamRequestCount(for id: PersistenceID) -> Int {
    self.eventStreamRequests[id, default: 0]
  }

  init() {}
}

private actor PullSource<Element: Sendable> {
  private let elements: [Element]
  private var index = 0
  private(set) var pullCount = 0

  init(_ elements: [Element]) {
    self.elements = elements
  }

  func next() -> Element? {
    self.pullCount += 1
    guard self.index < self.elements.count else { return nil }
    defer { self.index += 1 }
    return self.elements[self.index]
  }
}

private actor MemoryEventCursor<Event: Codable & Sendable> {
  private let kept: [(id: PersistenceID, sequenceNumber: Int64, offset: Offset, data: Data)]
  private var index = 0

  init(kept: [(id: PersistenceID, sequenceNumber: Int64, offset: Offset, data: Data)]) {
    self.kept = kept
  }

  func next() throws -> EventEnvelope<Event>? {
    guard self.index < self.kept.count else { return nil }
    let kept = self.kept[self.index]
    self.index += 1
    return EventEnvelope(
      persistenceID: kept.id,
      sequenceNumber: kept.sequenceNumber,
      offset: kept.offset,
      event: try JSONDecoder().decode(Event.self, from: kept.data)
    )
  }
}

actor MemorySnapshotStore: SnapshotStore, Sendable {

  private var dict: [PersistenceID: [(data: Data, covered: Int64)]] = [:]
  private let encoder: JSONEncoder = JSONEncoder()
  private let decoder: JSONDecoder = JSONDecoder()

  func save<State: Codable & Sendable>(_ state: State, id: PersistenceID, coveredSequenceNumber: Int64) throws {
    // Monotonic per the SnapshotStore contract: keep the highest covered.
    guard coveredSequenceNumber > (self.dict[id]?.last?.covered ?? 0) else { return }
    self.dict[id, default: []].append((try encoder.encode(state), coveredSequenceNumber))
  }

  func deleteSnapshots(id: PersistenceID, matching criteria: SnapshotSelectionCriteria) {
    self.dict[id]?.removeAll { criteria.includes($0.covered) }
  }

  func latestSnapshot<State: Codable & Sendable>(id: PersistenceID) throws -> Snapshot<State>? {
    guard let entry = self.dict[id]?.last,
      let state = try? self.decoder.decode(State.self, from: entry.data)
    else { return nil }
    return Snapshot(state: state, coveredSequenceNumber: entry.covered)
  }

  func coveredSequenceNumber(for id: PersistenceID) -> Int64? {
    self.dict[id]?.last?.covered
  }

  func coveredSequenceNumbers(for id: PersistenceID) -> [Int64] {
    self.dict[id, default: []].map(\.covered)
  }

  init() {}
}
