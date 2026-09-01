/// A persisted event together with its position in the journal.
/// Modeled after Akka Persistence Query's `EventEnvelope` — theirs
/// additionally carries offset/timestamp (and entity type/slice for
/// projections); grow this as those features land.
public struct EventEnvelope<Event: Codable & Sendable>: Codable, Sendable {
  public let persistenceID: PersistenceID
  public let sequenceNumber: Int64
  public let event: Event

  public init(persistenceID: PersistenceID, sequenceNumber: Int64, event: Event) {
    self.persistenceID = persistenceID
    self.sequenceNumber = sequenceNumber
    self.event = event
  }
}

public protocol EventStore: Sendable {
  /// Persist one event. This store holds the event log and nothing else —
  /// snapshots live in a separate `SnapshotStore`.
  ///
  /// Implementations must enforce uniqueness per `(id, sequenceNumber)`
  /// (e.g. a SQL unique constraint or expected-version check) and must throw
  /// on ANY persist to an already-used pair — identical payload or not.
  /// Writes are deliberately NOT idempotent (let-it-crash): when a persist
  /// fails over a network, the outcome is ambiguous — the event may have
  /// been rejected, or stored with the acknowledgement lost — and the store
  /// does not resolve that ambiguity. Recovery is replay-based: the caller
  /// drops the entity and re-registers, replaying the journal to re-sync
  /// state (see `ClusterJournalPlugin`, which also fails all later emits for
  /// the same persistence ID once a persist has failed).
  ///
  /// Events are kept forever by default; deletion is an explicit, separate
  /// decision (it destroys history for any other consumer of the log).
  func persistEvent<Event: Codable & Sendable>(
    _ event: Event,
    id: String,
    sequenceNumber: Int64
  ) async throws

  /// Finite stream of events with `sequenceNumber >= fromSequenceNumber`, in
  /// sequence order — completes once the journal is caught up (the analog of
  /// Akka Persistence Query's `currentEventsByPersistenceId`). This is THE
  /// read primitive: replay, and later projections, consume a stream rather
  /// than a fully buffered array, so implementations should pull rows on
  /// demand (index scan, `WHERE seq >= …`) instead of materializing the whole
  /// log.
  ///
  /// Sequence numbers are contiguous starting at 1, so
  /// `fromSequenceNumber: 1` reads the whole log; larger values are the read
  /// that makes snapshots actually save replay time (replay starts after the
  /// restored snapshot instead of scanning the whole log).
  ///
  /// Note: streams cannot cross the distributed-actor boundary, so the
  /// cluster-facing store pushes envelopes to a replay receiver; local store
  /// implementations and other local consumers use `eventStream` directly.
  func eventStream<Event: Codable & Sendable>(
    id: String,
    fromSequenceNumber: Int64
  ) async throws -> EventStream<Event>
}

/// A sendable asynchronous sequence of persisted event envelopes. The
/// existential preserves the concrete store's native iteration and
/// backpressure behavior without adding another stream implementation.
public typealias EventStream<Event: Codable & Sendable> =
  any AsyncSequence<EventEnvelope<Event>, any Error> & Sendable

extension EventStore {
  /// Events with `sequenceNumber >= fromSequenceNumber`, in sequence order —
  /// the whole suffix buffered into an array. Derived from `eventStream`;
  /// kept for callers that genuinely want the full log in memory.
  public func eventsFor<Event: Codable & Sendable>(
    id: String,
    fromSequenceNumber: Int64 = 1
  ) async throws -> [Event] {
    let stream: EventStream<Event> = try await self.eventStream(id: id, fromSequenceNumber: fromSequenceNumber)
    var events: [Event] = []
    for try await envelope in stream {
      events.append(envelope.event)
    }
    return events
  }
}
