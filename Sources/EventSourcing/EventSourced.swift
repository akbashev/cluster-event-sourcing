import Distributed
import DistributedCluster

@attached(member, names: named(sequenceNumber))
@attached(extension, conformances: EventSourced)
public macro EventSourced() = #externalMacro(module: "EventSourcingMacros", type: "EventSourcedMacro")

/**
 This is a starting point to create some Event Sourcing with actors, thus very rudimentary.

 References:
 1. https://doc.akka.io/docs/akka/current/typed/persistence.html
 2. https://doc.akka.io/docs/akka/current/persistence.html
 3. https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-persistence/?pivots=orleans-7-0
 4. https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing
 */

public typealias PersistenceID = String

/// Retention window for cadence-based snapshots.
///
/// This deliberately governs snapshots only. Event deletion changes recovery
/// semantics and belongs in a separate, explicit API.
public enum RetentionCriteria: Sendable {
  /// Never delete snapshots automatically.
  case keepAll
  /// Keep N periodic snapshot intervals (N ≥ 1). Predicate snapshots within
  /// that sequence-number window may remain as additional snapshots.
  case keepLast(Int)
}

/// Snapshotting policy of an entity type (see `EventSourced.snapshotting`).
///
/// Checkpoints are an opportunistic optimization living in a separate
/// `SnapshotStore`: replay restores the latest snapshot if one decodes and
/// otherwise falls back to the full event log, so the policy never enters the
/// semantics — different cadences across nodes or rolling upgrades only change
/// replay length, never outcomes.
public enum Snapshotting<Event: Sendable, State: Sendable>: Sendable {
  case disabled
  /// Save a state snapshot on every Nth emitted event (N ≥ 1), or when the
  /// optional domain rule matches. The supplied retention policy runs only
  /// after periodic snapshots, matching Akka's retention semantics.
  case every(
    numberOfEvents: Int,
    retention: RetentionCriteria,
    orWhen: (@Sendable (Event, State, Int64) -> Bool)?
  )
  /// Save a state snapshot when the rule — evaluated with the just-applied
  /// event, the post-event state, and its sequence number — returns true.
  /// Lets an entity snapshot at domain-meaningful moments (e.g. right after
  /// a compaction event shrank the state) instead of on a fixed cadence;
  /// compare Akka Persistence's `snapshotWhen` predicate.
  case when(@Sendable (Event, State, Int64) -> Bool)
  /// Convenience spelling for purely periodic snapshotting; keeps the
  /// optional `orWhen` implementation detail out of the common call site.
  public static func every(
    numberOfEvents: Int,
    retention: RetentionCriteria = .keepAll
  ) -> Self {
    .every(numberOfEvents: numberOfEvents, retention: retention, orWhen: nil)
  }
}

public protocol EventSourced: DistributedActor where ActorSystem == ClusterSystem {
  associatedtype Event: Codable & Sendable
  /// The actor's whole state as a single `Codable` value. Snapshots are taken
  /// from and restored into this property, so all persistent state must live
  /// behind it (transient state can use separate properties outside of it).
  associatedtype State: Codable & Sendable
  var sequenceNumber: Int64 { get set }
  var state: State { get set }
  /// Snapshot cadence of this entity type. Expressed in code (not plugin
  /// config) so the policy and retention travel with the entity wherever it
  /// is hosted. Defaults to `.disabled` (see extension below).
  var snapshotting: Snapshotting<Event, State> { get }
  func handleEvent(_ event: Event)
}

extension EventSourced {
  public var snapshotting: Snapshotting<Event, State> { .disabled }
}
