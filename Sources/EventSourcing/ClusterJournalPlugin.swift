import AsyncAlgorithms
public import Distributed
public import DistributedCluster
import Logging

public actor ClusterJournalPlugin {

  private var actorSystem: ClusterSystem!
  private var store: AnyEventStore!
  private var snapshotStore: AnySnapshotStore!

  private var factory: @Sendable (ClusterSystem) async throws -> (any EventStore)
  private var snapshotFactory: (@Sendable (ClusterSystem) async throws -> any SnapshotStore)?
  private var emitTasks: [PersistenceID: Task<Void, any Error>] = [:]
  private var registeredActors: [ClusterSystem.ActorID: PersistenceID] = [:]

  public enum RegistrationError: Error {
    case notRegistered(ClusterSystem.ActorID)
    case alreadyRegistered(ClusterSystem.ActorID, existingPersistenceID: PersistenceID)
  }

  public enum SnapshottingError: Error {
    /// Snapshotting is enabled on the entity but the plugin was created
    /// without a snapshot store factory.
    case storeNotConfigured
    /// `.keepLast` requires a positive snapshot count.
    case invalidRetentionCount(Int)
  }

  public func emit<E: Codable & Sendable>(
    _ event: E,
    id: ClusterSystem.ActorID,
    sequenceNumber: Int64,
    tags: Set<EventTag>
  ) async throws {
    guard let persistenceId = self.registeredActors[id] else {
      throw RegistrationError.notRegistered(id)
    }

    // Capture at enqueue time: this task may outlive `stop()`, which clears the
    // plugin's IUOs. Unwrapping actor state at execution time crashes the process.
    // The explicit annotations force-unwrap here, which is safe: `emit` is
    // actor-isolated and serialized with `stop()`, and post-stop emits fail the
    // `registeredActors` guard above before reaching this point. Only the logger
    // is taken from the system so a late task does not keep the whole
    // ClusterSystem alive during shutdown.
    // Post-stop emits pass the `registeredActors` guard above (stop does not
    // clear it) and would unwrap the cleared IUOs — fail the emit loudly
    // instead (same shutdown race as `restoreEventsFor`).
    guard let store, let actorSystem else {
      throw CancellationError()
    }
    let log: Logger = actorSystem.log

    // Task chaining: each persist awaits the previous one, so events land in
    // the store in emission order. Rethrowing the previous task's failure is
    // DELIBERATE: once a persist fails, every later emit for this persistence
    // ID fails too (without attempting a write), for two reasons:
    //   1. Safety: a failed write is ambiguous — the event may actually have
    //      been stored with its acknowledgement lost — so the journal can no
    //      longer be trusted and must not silently accept new events.
    //   2. Consistency under reentrancy: overlapping emits all fail and roll
    //      back in lockstep, keeping `sequenceNumber`, live state and journal
    //      in agreement (see `EventSourced.emit`).
    // Recovery is the caller's responsibility: drop the actor — its ID
    // resigning clears this chain (`removeActorWith`) — and re-`register`,
    // which replays the journal and re-syncs state from it.
    // NOTE: failure/retry/recovery semantics are intentionally minimal and
    // will be revisited (planned after snapshotting). Do not "fix" the
    // stickiness without designing that model first.
    let emitTask = self.emitTasks[persistenceId]
    let task = Task { [emitTask, store, log] in
      _ = try await emitTask?.value
      guard !Task.isCancelled else { throw CancellationError() }
      try await store.persistEvent(event, id: persistenceId, sequenceNumber: sequenceNumber, tags: tags)
      log.debug("Emitted event: \(event) for actor with id: \(persistenceId)")
    }
    self.emitTasks[persistenceId] = task
    return try await task.value
  }

  /// Best-effort snapshot save and retention: the event log is complete
  /// without either, so a failure here is logged by the caller and never fails
  /// the emit (compare Akka's non-fatal snapshot and deletion signals).
  public func saveSnapshot<State: Codable & Sendable>(
    _ state: State,
    id: ClusterSystem.ActorID,
    coveredSequenceNumber: Int64,
    retention: RetentionCriteria,
    periodicSnapshotEvery: Int?
  ) async throws {
    guard let persistenceId = self.registeredActors[id] else {
      throw RegistrationError.notRegistered(id)
    }
    guard let snapshotStore else {
      throw SnapshottingError.storeNotConfigured
    }
    if case .keepLast(let count) = retention, count < 1 {
      throw SnapshottingError.invalidRetentionCount(count)
    }
    try await snapshotStore.save(state, id: persistenceId, coveredSequenceNumber: coveredSequenceNumber)
    if case .keepLast(let count) = retention,
      let numberOfEvents = periodicSnapshotEvery,
      let interval = Int64(exactly: numberOfEvents)
    {
      let (distance, overflowed) = interval.multipliedReportingOverflow(by: Int64(count))
      let (cutoff, underflowed) = coveredSequenceNumber.subtractingReportingOverflow(distance)
      if !overflowed, !underflowed, cutoff >= 1 {
        try await snapshotStore.deleteSnapshots(
          id: persistenceId,
          matching: .through(cutoff)
        )
      }
    }
  }

  /// Registers `actor` as `persistenceID`, recovering its state from the
  /// journal first. It runs in `actor`'s own isolation, as the actor's init
  /// calls it: the recovery changes the actor's state directly, and only
  /// asks the plugin for what's its to give.
  public func register<A: EventSourced>(actor: isolated A, with persistenceID: PersistenceID) async throws {
    try await self.unregistered(actor.id)
    try await self.restore(actor, id: persistenceID)
    await self.registered(actor.id, as: persistenceID)
  }

  /// `actor`'s state recovered, in its isolation: from its latest snapshot when
  /// one loads, then every event after it, each applied as the store sends it.
  private func restore<A: EventSourced>(_ actor: isolated A, id persistenceId: PersistenceID) async throws {
    try Task.checkCancellation()
    let (store, snapshotStore, actorSystem) = try await self.journal()

    // Phase 1: restore from the latest snapshot if one is available. A
    // snapshot that cannot be loaded (store down, undecodable after a State
    // schema change) falls back to full replay — the log is complete.
    let snapshot: Snapshot<A.State>? =
      if let snapshotStore { try? await snapshotStore.latestSnapshot(id: persistenceId) } else { nil }
    if let snapshot {
      actor.state = snapshot.state
      actor.sequenceNumber = snapshot.coveredSequenceNumber
    }
    let fromSequenceNumber = (snapshot?.coveredSequenceNumber ?? 0) + 1
    try Task.checkCancellation()

    // Phase 2: the store singleton pushes each event to a temporary receiver,
    // as Akka's ReplayMessages/ReplayedMessage do, so the stream stays beside
    // the store. The receiver hands each one over a channel that waits until
    // it's applied here: one event at a time, as the actor's own work.
    let replayed = AsyncChannel<EventEnvelope<A.Event>>()
    // An actor no longer taking events lets the store finish its replay.
    defer { replayed.finish() }
    let receiver = EventReplayReceiver<A.Event>(actorSystem: actorSystem) { envelope in
      await replayed.send(envelope)
    }
    async let replaying: Void = {
      defer { replayed.finish() }
      try await store.replay(id: persistenceId, fromSequenceNumber: fromSequenceNumber, receiver: receiver)
    }()
    for await envelope in replayed {
      // A cancelled activation must fail loudly, never come up stale: after a
      // snapshot restore the sequence number is already advanced, so silently
      // skipping the fold would register the actor as current while it is
      // behind the journal.
      try Task.checkCancellation()
      actor.handleEvent(envelope.event)
      actor.sequenceNumber = envelope.sequenceNumber
    }
    try await replaying
    try Task.checkCancellation()
    actorSystem.log.debug(
      "Restored actor with id: \(persistenceId), applied \(max(0, actor.sequenceNumber - fromSequenceNumber + 1)) events"
    )
  }

  /// The stores and the system recovery reads from: refused once the plugin
  /// stopped, as a restore during shutdown must fail loudly, never crash the
  /// process or bring an actor up believing it is current on an empty replay.
  private func journal() throws -> (AnyEventStore, AnySnapshotStore?, ClusterSystem) {
    guard let store, let actorSystem else { throw CancellationError() }
    return (store, snapshotStore, actorSystem)
  }

  /// Refused when `id` is registered already.
  private func unregistered(_ id: ClusterSystem.ActorID) throws {
    if let existing = self.registeredActors[id] {
      throw RegistrationError.alreadyRegistered(id, existingPersistenceID: existing)
    }
  }

  private func registered(_ id: ClusterSystem.ActorID, as persistenceID: PersistenceID) {
    self.registeredActors[id] = persistenceID
  }

  fileprivate func removeActorWith(id: ClusterSystem.ActorID) {
    guard let persistenceId = self.registeredActors[id] else { return }
    self.emitTasks[persistenceId]?.cancel()
    self.emitTasks.removeValue(forKey: persistenceId)
    self.registeredActors.removeValue(forKey: id)
  }

  fileprivate func stopTasks() {
    for task in self.emitTasks {
      task.value.cancel()
    }
    self.emitTasks.removeAll()
    self.registeredActors.removeAll()
  }

  public init(
    factory: @Sendable @escaping (ClusterSystem) async throws -> any EventStore,
    snapshotFactory: (@Sendable (ClusterSystem) async throws -> any SnapshotStore)? = nil
  ) {
    self.factory = factory
    self.snapshotFactory = snapshotFactory
  }
}

extension ClusterJournalPlugin: ActorLifecyclePlugin {
  static let pluginKey: Key = "$clusterJournal"

  public nonisolated var key: Key {
    Self.pluginKey
  }

  public func start(_ system: ClusterSystem) async throws {
    self.actorSystem = system
    self.store =
      try await system
      .singleton
      .host(name: "\(ClusterJournalPlugin.pluginKey)_store") {
        try await AnyEventStore(actorSystem: $0, store: self.factory($0))
      }
    if let snapshotFactory = self.snapshotFactory {
      self.snapshotStore =
        try await system
        .singleton
        .host(name: "\(ClusterJournalPlugin.pluginKey)_snapshots") {
          try await AnySnapshotStore(actorSystem: $0, store: snapshotFactory($0))
        }
    }
  }

  public func stop(_ system: ClusterSystem) async {
    self.stopTasks()
    self.actorSystem = nil
    self.store = nil
    self.snapshotStore = nil
  }

  nonisolated public func onActorReady<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {}

  nonisolated public func onResignID(_ id: DistributedCluster.ClusterSystem.ActorID) {
    Task.immediate { [weak self] in
      await self?.removeActorWith(id: id)
    }
  }

}

extension ClusterSystem {

  public var journal: ClusterJournalPlugin {
    let key = ClusterJournalPlugin.pluginKey
    guard let journalPlugin = self.settings.plugins[key] else {
      fatalError("No plugin found for key: [\(key)], installed plugins: \(self.settings.plugins)")
    }
    return journalPlugin
  }
}

extension EventSourced {
  /// Increments `sequenceNumber`, persists the event with its tags (see
  /// `tagging`), and only then applies it
  /// to live state. On any failure the sequence number is rolled back and the
  /// error rethrown — the actor never applies an event that didn't reach the
  /// journal, and what to do next (retry, drop the actor, …) is the caller's
  /// decision. Note that after a persist failure the journal refuses all
  /// later emits for this persistence ID (see the task-chaining comment in
  /// `ClusterJournalPlugin.emit`); the rollback stays consistent because those
  /// cascading emits roll back too.
  ///
  /// Snapshotting (see `snapshotting`): a successful emit also saves a
  /// snapshot of the post-event state when the policy says so — every Nth
  /// event for `.every`, whenever the rule returns true for `.when`, or when
  /// either condition matches for `.every(..., orWhen:)`. The save is
  /// BEST-EFFORT — the event log is complete without it, so a failure is
  /// logged and never fails the emit (compare Akka's non-fatal
  /// `SnapshotFailed` signal).
  public func emit(event: Event) async throws {
    self.sequenceNumber += 1
    do {
      try await self.actorSystem.journal.emit(
        event,
        id: self.id,
        sequenceNumber: self.sequenceNumber,
        tags: self.tagging.tags(for: event)
      )
      self.handleEvent(event)
    } catch {
      self.sequenceNumber -= 1
      throw error
    }

    let snapshotRequest: (retention: RetentionCriteria, periodicSnapshotEvery: Int?)?
    switch self.snapshotting {
    case .disabled:
      snapshotRequest = nil
    case .every(let numberOfEvents, let configuredRetention, let rule):
      let isPeriodic =
        numberOfEvents > 0 && self.sequenceNumber % Int64(numberOfEvents) == 0
      if isPeriodic {
        snapshotRequest = (configuredRetention, numberOfEvents)
      } else if rule?(event, self.state, self.sequenceNumber) == true {
        snapshotRequest = (.keepAll, nil)
      } else {
        snapshotRequest = nil
      }
    case .when(let rule):
      snapshotRequest =
        rule(event, self.state, self.sequenceNumber)
        ? (.keepAll, nil)
        : nil
    }
    if let snapshotRequest {
      do {
        try await self.actorSystem.journal.saveSnapshot(
          self.state,
          id: self.id,
          coveredSequenceNumber: self.sequenceNumber,
          retention: snapshotRequest.retention,
          periodicSnapshotEvery: snapshotRequest.periodicSnapshotEvery
        )
      } catch {
        self.actorSystem.log.warning(
          "Snapshot save or retention cleanup failed for actor with id: \(self.id) at sequence number \(self.sequenceNumber): \(error)"
        )
      }
    }
  }
}

/// Not sure if it's correct way, basically wrapping `any EventStore` into `AnyEventStore` which is singleton.
/// Deliberately NOT an `EventStore`: a distributed actor may only satisfy
/// protocol requirements with `distributed` witnesses, and `eventStream`
/// cannot be distributed (streams don't cross the wire) — so this wrapper
/// pushes replay envelopes to a temporary receiver because streams cannot
/// cross the distributed-actor boundary. Local streaming consumers should use
/// the concrete store (or `any EventStore`) directly. Across nodes, this is one
/// acknowledged distributed call per envelope; long journals may eventually
/// need an internal batched transport while preserving this streaming API.
distributed actor AnyEventStore: ClusterSingleton {

  private var store: any EventStore

  distributed func persistEvent<Event: Codable & Sendable>(
    _ event: Event,
    id: PersistenceID,
    sequenceNumber: Int64,
    tags: Set<EventTag>
  ) async throws {
    try await self.store.persistEvent(event, id: id, sequenceNumber: sequenceNumber, tags: tags)
  }

  distributed func replay<Event: Codable & Sendable>(
    id: PersistenceID,
    fromSequenceNumber: Int64,
    receiver: EventReplayReceiver<Event>
  ) async throws {
    let stream: EventStream<Event> = try await self.store.eventStream(
      id: id,
      fromSequenceNumber: fromSequenceNumber
    )
    for try await envelope in stream {
      try await receiver.replay(envelope)
    }
  }

  init(
    actorSystem: ActorSystem,
    store: any EventStore
  ) {
    self.actorSystem = actorSystem
    self.store = store
  }
}

/// Temporary endpoint for one recovery. `AnyEventStore` pushes envelopes into
/// it one at a time; a push is not acknowledged until `consume` returns.
distributed actor EventReplayReceiver<Event: Codable & Sendable> {

  typealias ActorSystem = ClusterSystem

  private let consume: @Sendable (EventEnvelope<Event>) async throws -> Void

  distributed func replay(_ envelope: EventEnvelope<Event>) async throws {
    try await self.consume(envelope)
  }

  init(
    actorSystem: ClusterSystem,
    consume: @escaping @Sendable (EventEnvelope<Event>) async throws -> Void
  ) {
    self.actorSystem = actorSystem
    self.consume = consume
  }
}

/// Same wrapping as `AnyEventStore`, for the optional snapshot store.
distributed actor AnySnapshotStore: SnapshotStore, ClusterSingleton {

  private var store: any SnapshotStore

  distributed func save<State: Codable & Sendable>(_ state: State, id: PersistenceID, coveredSequenceNumber: Int64) async throws {
    try await self.store.save(state, id: id, coveredSequenceNumber: coveredSequenceNumber)
  }

  distributed func latestSnapshot<State: Codable & Sendable>(id: PersistenceID) async throws -> Snapshot<State>? {
    try await self.store.latestSnapshot(id: id)
  }

  distributed func deleteSnapshots(
    id: PersistenceID,
    matching criteria: SnapshotSelectionCriteria
  ) async throws {
    try await self.store.deleteSnapshots(id: id, matching: criteria)
  }

  init(
    actorSystem: ActorSystem,
    store: any SnapshotStore
  ) {
    self.actorSystem = actorSystem
    self.store = store
  }
}
