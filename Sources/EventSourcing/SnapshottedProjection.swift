/// A read side whose whole state is folded, in memory, from every event with
/// one tag, and kept in the `SnapshotStore` with the offset it covers: every
/// `snapshotEvery` events, under `name`. Each run starts from its latest
/// snapshot, or from the tag's beginning without one, so it reads only what
/// was kept after it. The state and its offset are saved as one value, so they
/// never disagree, and no read-model table is needed. Compare Akka
/// Projections, which keep the offset in an offset store beside the read
/// model.
///
/// The snapshot's covered sequence number is the offset it covers: a
/// projection's offsets only grow, so the store's latest is its newest. As any
/// snapshot, it's an optimization: one that no longer decodes is read as none,
/// and the tag is read from its beginning again. A failed save is told to
/// `snapshotFailed` and the projection goes on, as a failed entity snapshot
/// never fails its emit.
///
/// `fold` makes the state an event leaves, and does nothing else. `started`
/// hears the state a run starts from, and `applied` each state an event makes,
/// with that event: the read side's own view of it.
///
/// It reads the store directly, beside the concrete store; exactly one should
/// run for a read side, as for `Projection`.
public struct SnapshottedProjection<Event: Codable & Sendable, State: Codable & Sendable>: Sendable {
  /// What its snapshots are kept under: never an entity's persistence ID.
  public let name: PersistenceID
  public let tag: EventTag
  /// The state before any event.
  public let initial: State
  /// How many events it reads between snapshots (≥ 1).
  public let snapshotEvery: Int
  public let fold: @Sendable (State, EventEnvelope<Event>) throws -> State
  public let started: @Sendable (State) async throws -> Void
  public let applied: @Sendable (State, EventEnvelope<Event>) async throws -> Void

  public init(
    name: PersistenceID,
    tag: EventTag,
    initial: State,
    snapshotEvery: Int,
    fold: @escaping @Sendable (State, EventEnvelope<Event>) throws -> State,
    started: @escaping @Sendable (State) async throws -> Void,
    applied: @escaping @Sendable (State, EventEnvelope<Event>) async throws -> Void
  ) {
    self.name = name
    self.tag = tag
    self.initial = initial
    self.snapshotEvery = max(snapshotEvery, 1)
    self.fold = fold
    self.started = started
    self.applied = applied
  }

  /// Keeps the read side up with `store` until the task running it is
  /// cancelled, which ends it with `CancellationError`, starting from its
  /// latest snapshot in `snapshots`; a failed read, `fold`, `started` or
  /// `applied` ends it with that error. It never ends otherwise.
  public func run(
    on store: any EventStore,
    snapshots: any SnapshotStore,
    refreshInterval: Duration = .seconds(1),
    snapshotFailed: @Sendable (any Error) -> Void
  ) async throws -> Never {
    let latest: Snapshot<State>? = try await snapshots.latestSnapshot(id: self.name)
    var state = latest?.state ?? self.initial
    var after = latest.map { Offset($0.coveredSequenceNumber) } ?? .start
    var sinceSnapshot = 0
    try await self.started(state)
    while true {
      let events: EventStream<Event> = try await store.currentEventsByTag(self.tag, after: after)
      for try await envelope in events {
        try Task.checkCancellation()
        state = try self.fold(state, envelope)
        after = envelope.offset
        try await self.applied(state, envelope)
        sinceSnapshot += 1
        if sinceSnapshot >= self.snapshotEvery {
          sinceSnapshot = 0
          do {
            try await snapshots.save(state, id: self.name, coveredSequenceNumber: after.rawValue)
            // Only the newest is read again: the ones before it are let go.
            try await snapshots.deleteSnapshots(id: self.name, matching: .through(after.rawValue - 1))
          } catch {
            snapshotFailed(error)
          }
        }
      }
      try await Task.sleep(for: refreshInterval)
    }
  }

  /// Keeps the read side up with `store` until the task running it is
  /// cancelled, starting again after it fails, from its latest snapshot:
  /// `failed` hears each failure, a snapshot's too, and `restartAfter` after
  /// a run fails it runs again.
  public func runRestarting(
    on store: any EventStore,
    snapshots: any SnapshotStore,
    refreshInterval: Duration = .seconds(1),
    restartAfter: Duration = .seconds(5),
    failed: @Sendable (any Error) -> Void
  ) async {
    while !Task.isCancelled {
      do {
        try await self.run(on: store, snapshots: snapshots, refreshInterval: refreshInterval, snapshotFailed: failed)
      } catch is CancellationError {
        return
      } catch {
        failed(error)
        // Cancelled while it waits, it ends at the loop's check.
        try? await Task.sleep(for: restartAfter)
      }
    }
  }
}
