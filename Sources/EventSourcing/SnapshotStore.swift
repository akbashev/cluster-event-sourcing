/// A persisted snapshot of an actor's state at a point in the event log.
public struct Snapshot<State: Codable & Sendable>: Codable, Sendable {
  public var state: State
  /// The sequence number the state covers — i.e. state after applying events
  /// 1...coveredSequenceNumber. Replay continues from coveredSequenceNumber+1.
  public var coveredSequenceNumber: Int64

  public init(state: State, coveredSequenceNumber: Int64) {
    self.state = state
    self.coveredSequenceNumber = coveredSequenceNumber
  }
}

/// Storage for actor state snapshots — an OPTIONAL add-on next to the
/// `EventStore` (which holds the event log and nothing else). The system is
/// fully functional without a snapshot store: entities journal and replay
/// events as usual, and only snapshot saves fail (loudly, at save time).
///
/// Snapshots are a best-effort optimization over a complete log: the journal
/// logs save failures and continues, and a snapshot that cannot be loaded
/// falls back to full replay (compare Akka, where snapshot-write failure is
/// non-fatal and snapshot-load failure is recoverable).
public protocol SnapshotStore: Sendable {
  /// Persist a snapshot. Encoding is owned by the store, as with events.
  ///
  /// Implementations must be idempotent and monotonic per `id`: re-saving the
  /// same `coveredSequenceNumber` is a no-op, and a save with a
  /// `coveredSequenceNumber` lower than an already-stored one must be ignored
  /// (racing actor incarnations may save out of order) — `latestSnapshot`
  /// always returns the snapshot with the highest covered sequence number.
  func save<State: Codable & Sendable>(
    _ state: State,
    id: PersistenceID,
    coveredSequenceNumber: Int64
  ) async throws

  /// The snapshot with the highest covered sequence number, or nil.
  ///
  /// Retention (keep latest, keep N) is store-internal. Tolerant decode is
  /// expected as with events: a snapshot that no longer decodes after a
  /// `State` schema change should be treated as absent (nil) rather than
  /// failing the read — the journal then falls back to full replay.
  func latestSnapshot<State: Codable & Sendable>(id: PersistenceID) async throws -> Snapshot<State>?
}
