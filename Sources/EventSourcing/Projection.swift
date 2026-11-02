/// A read side kept from every event with one tag, across all entities: the
/// answer to a question no single entity holds, such as which entities a
/// person is in. Compare Akka Projections.
///
/// `run` reads the events tagged `tag` after the offset `offset` gives, hands
/// each to `process` in offset order, and once caught up asks again every
/// `refreshInterval`, until its task is cancelled. Compare Akka Persistence
/// JDBC's `eventsByTag`, which polls the same way.
///
/// `process` keeps the event's change and the envelope's offset, which is
/// where the next `run` starts. Kept in one transaction, each event counts
/// exactly once. Kept one after the other, an event whose offset wasn't kept
/// yet is given again after a restart, so `process` must then leave the read
/// side as the first time did (Akka's at-least-once, with an idempotent
/// handler).
///
/// It reads the store directly, so it runs beside the concrete store, not
/// through the cluster: streams don't cross the distributed-actor boundary.
/// Exactly one should run for a read side; a `ClusterSingleton` hosting it
/// keeps it that way.
public struct Projection<Event: Codable & Sendable>: Sendable {
  public let tag: EventTag
  /// Where the read side has read up to: `Offset.start` when it's read nothing.
  public let offset: @Sendable () async throws -> Offset
  /// Keeps one event's change, and its envelope's offset.
  public let process: @Sendable (EventEnvelope<Event>) async throws -> Void

  public init(
    tag: EventTag,
    offset: @escaping @Sendable () async throws -> Offset,
    process: @escaping @Sendable (EventEnvelope<Event>) async throws -> Void
  ) {
    self.tag = tag
    self.offset = offset
    self.process = process
  }

  /// Keeps the read side up with `store` until the task running it is
  /// cancelled, which ends it with `CancellationError`; a failed read or
  /// `process` ends it with that error. It never ends otherwise.
  public func run(on store: any EventStore, refreshInterval: Duration = .seconds(1)) async throws -> Never {
    var after = try await self.offset()
    while true {
      let events: EventStream<Event> = try await store.currentEventsByTag(self.tag, after: after)
      for try await envelope in events {
        try Task.checkCancellation()
        try await self.process(envelope)
        after = envelope.offset
      }
      try await Task.sleep(for: refreshInterval)
    }
  }

  /// Keeps the read side up with `store` until the task running it is
  /// cancelled, starting again after it fails, as Akka Projections restarts a
  /// failed projection: `failed` hears each failure, and `restartAfter` later
  /// it runs again from the offset the read side kept.
  public func runRestarting(
    on store: any EventStore,
    refreshInterval: Duration = .seconds(1),
    restartAfter: Duration = .seconds(5),
    failed: @Sendable (any Error) -> Void
  ) async {
    while !Task.isCancelled {
      do {
        try await self.run(on: store, refreshInterval: refreshInterval)
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
