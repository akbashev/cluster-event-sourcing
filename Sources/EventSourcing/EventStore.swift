public protocol EventStore: Sendable {
  /// Persist one event. This store holds the event log and nothing else —
  /// snapshots live in a separate `SnapshotStore`.
  ///
  /// Implementations must make writes idempotent per `(id, sequenceNumber)`:
  /// the pair is unique (e.g. a SQL unique constraint or expected-version
  /// check), re-persisting an already-stored sequence number with the same
  /// payload is a no-op, and persisting a *different* event at an
  /// already-used sequence number must throw. When a persist fails over a
  /// network, the outcome is indistinguishable — the event may have been
  /// rejected, or stored with the acknowledgement lost — and callers retry
  /// failed emits with the same sequence number; only idempotent,
  /// uniqueness-enforcing stores keep such retries from producing duplicates.
  ///
  /// Events are kept forever by default; deletion is an explicit, separate
  /// decision (it destroys history for any other consumer of the log).
  func persistEvent<Event: Codable & Sendable>(
    _ event: Event,
    id: String,
    sequenceNumber: Int64
  ) async throws

  /// Events with `sequenceNumber >= fromSequenceNumber`, in sequence order.
  /// Sequence numbers are contiguous starting at 1, so
  /// `fromSequenceNumber: 1` reads the whole log; larger values are the read
  /// that makes snapshots actually save replay time (replay starts after the
  /// restored snapshot instead of scanning the whole log). Implement with a
  /// real suffix read where possible (index scan, `WHERE seq >= …`).
  func eventsFor<Event: Codable & Sendable>(
    id: String,
    fromSequenceNumber: Int64
  ) async throws
    -> [Event]
}

extension EventStore {
  /// All events for a persistence ID, in sequence order.
  public func eventsFor<Event: Codable & Sendable>(id: String) async throws -> [Event] {
    try await self.eventsFor(id: id, fromSequenceNumber: 1)
  }
}
