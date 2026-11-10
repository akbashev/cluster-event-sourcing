/// A read side kept from every event with one tag, across all entities: the
/// answer to a question no single entity holds, such as which entities a
/// person is in. Compare Akka Projections.
///
/// `run` reads the events tagged `tag` after the offset `offset` gives, hands
/// each to `process` in offset order, and once caught up asks again every
/// `refreshInterval`, until its task is cancelled. Compare Akka Persistence
/// JDBC's `eventsByTag`, which polls the same way.
///
/// It runs on the isolation it's given, its caller's by default: run inside a
/// read side's actor, `offset` and `process` are that actor's own code, which
/// read and change its state directly.
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

  public init(tag: EventTag) {
    self.tag = tag
  }

  /// Keeps the read side up with `store` until the task running it is
  /// cancelled, which ends it with `CancellationError`; a failed read, `offset`
  /// or `process` ends it with that error. It never ends otherwise.
  ///
  /// - Parameters:
  ///   - isolation: Where it runs, and `offset` and `process` with it.
  ///   - offset: Where the read side has read up to: `Offset.start` when it's
  ///     read nothing.
  ///   - process: Keeps one event's change, and its envelope's offset.
  public func run(
    on store: any EventStore,
    refreshInterval: Duration = .seconds(1),
    isolation: isolated (any Actor)? = #isolation,
    offset: () async throws -> Offset,
    process: (EventEnvelope<Event>) async throws -> Void
  ) async throws -> Never {
    var after = try await offset()
    while true {
      let events: EventStream<Event> = try await store.currentEventsByTag(self.tag, after: after)
      for try await envelope in events {
        try Task.checkCancellation()
        try await process(envelope)
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
    isolation: isolated (any Actor)? = #isolation,
    offset: () async throws -> Offset,
    process: (EventEnvelope<Event>) async throws -> Void,
    failed: (any Error) -> Void
  ) async {
    while !Task.isCancelled {
      do {
        try await self.run(
          on: store,
          refreshInterval: refreshInterval,
          isolation: isolation,
          offset: offset,
          process: process
        )
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
