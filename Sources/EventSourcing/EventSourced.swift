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

/// Snapshotting policy of an entity type (see `EventSourced.snapshotting`).
///
/// Checkpoints are an opportunistic optimization living in a separate
/// `SnapshotStore`: replay restores the latest snapshot if one decodes and
/// otherwise falls back to the full event log, so the policy never enters the
/// semantics — different cadences across nodes or rolling upgrades only change
/// replay length, never outcomes.
public enum Snapshotting: Sendable {
  case disabled
  /// Save a state snapshot on every Nth emitted event (N ≥ 1).
  case enabled(every: Int)
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
  /// config) so the policy travels with the entity wherever it is hosted —
  /// the same shape as Akka's per-behavior `RetentionCriteria`. Defaults to
  /// `.disabled` (see extension below).
  var snapshotting: Snapshotting { get }
  func handleEvent(_ event: Event)
}

extension EventSourced {
  public var snapshotting: Snapshotting { .disabled }
}
