# Cluster Event Sourcing

Event sourcing for Swift distributed actors, built on [swift-distributed-actors](https://github.com/apple/swift-distributed-actors)—the [Akka persistence](https://doc.akka.io/docs/akka/current/typed/persistence.html) / [Orleans grain persistence](https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-persistence/) model, with Swift concurrency at its core.

Don't store your actor's state—store the events that produced it. Every state change is journaled as an immutable, sequenced event; on restart the actor replays its journal and rebuilds its state exactly. Crashes, rebalancing, and passivation stop being data-loss scenarios.

```swift
@EventSourced
distributed actor OrderActor {

  struct State: Codable, Sendable {
    var items: [Item: Int] = [:]
  }

  enum Event: Codable, Sendable {
    case itemAdded(item: Item, count: Int)
  }

  var state: State = .init()

  distributed func add(item: Item, count: Int) async throws {
    try await self.emit(event: .itemAdded(item: item, count: count))
  }

  distributed func handleEvent(_ event: Event) {
    switch event {
    case .itemAdded(let item, let count):
      state.items[item, default: 0] += count
    }
  }

  init(actorSystem: ClusterSystem) async throws {
    self.actorSystem = actorSystem
    try await actorSystem.journal.register(actor: self, with: "order-42")
  }
}
```

## Why event sourcing?

- **State is a replay, not a snapshot.** The journal is the source of truth. An actor's in-memory state is derived by folding its events through `handleEvent(_:)`—the same function that applies them live.
- **Crash recovery for free.** `register(actor:with:)` replays the journal before the actor serves calls. A crashed or restarted actor comes back with the exact state it had.
- **Every event is sequenced.** Each actor carries a `sequenceNumber: Int64` (added by the `@EventSourced` macro). `emit(event:)` increments it, persists with it, and rolls it back if the persist fails—so gaps and duplicates in the journal are detectable by your store.
- **Ordered writes, per actor.** Persists for one persistence ID are task-chained inside the journal—events land in the store in emission order, never interleaved.
- **Cluster-wide store.** Your `EventStore` is wrapped in a distributed actor hosted as a cluster singleton, so every node journals to and replays from the same place.
- **Bring your own storage.** The package ships no store implementations. `EventStore` is a two-method protocol—back it with Postgres, files, FoundationDB, or an in-memory dictionary for tests.

## Quick start

Install the plugins (order matters—the journal hosts its store as a cluster singleton):

```swift
let system = await ClusterSystem("my-node") {
  $0.plugins.install(plugin: ClusterSingletonPlugin())
  $0.plugins.install(
    plugin: ClusterJournalPlugin { _ in
      PostgresEventStore()  // your EventStore
    }
  )
}
```

The factory is `@Sendable (ClusterSystem) async throws -> any EventStore`, so store setup can itself be asynchronous.

Implement `EventStore`:

```swift
protocol EventStore: Sendable {
  func persistEvent<Event: Codable & Sendable>(
    _ event: Event, id: String, sequenceNumber: Int64
  ) async throws
  func eventsFor<Event: Codable & Sendable>(
    id: String, fromSequenceNumber: Int64
  ) async throws -> [Event]
}
```

`eventsFor(id:fromSequenceNumber:)` must return events with `sequenceNumber >= fromSequenceNumber` in journal order—replay folds them in the order you return them. Sequence numbers are contiguous from 1, so `fromSequenceNumber: 1` reads the whole log (also available as the `eventsFor(id:)` extension convenience); larger values are what let snapshots skip replay.

Declare the actor. The `@EventSourced` macro adds the `EventSourced` conformance and the `sequenceNumber` storage; you provide the `Event` and `State` types, the `state` property, `handleEvent(_:)`, and registration in `init`:

```swift
@EventSourced
distributed actor OrderActor {

  struct State: Codable, Sendable {
    var items: [Item: Int] = [:]
  }

  enum Event: Codable, Sendable {
    case itemAdded(item: Item, count: Int)
  }

  var state: State = .init()

  distributed func add(item: Item, count: Int) async throws {
    try await self.emit(event: .itemAdded(item: item, count: count))
  }

  distributed func handleEvent(_ event: Event) {
    switch event {
    case .itemAdded(let item, let count):
      state.items[item, default: 0] += count
    }
  }

  init(actorSystem: ClusterSystem) async throws {
    self.actorSystem = actorSystem
    try await actorSystem.journal.register(actor: self, with: "order-42")
  }
}
```

What the macro expands to, exactly:

```swift
// inside the actor:
public var sequenceNumber: Int64 = 0

// alongside it:
extension OrderActor: EventSourced {}
```

## How emit and replay work, precisely

`emit(event:)` runs on the actor's own executor (`whenLocal`) and is the only way events should be produced:

1. `sequenceNumber` is incremented.
2. The event is persisted through the journal with that sequence number. Persists for the same persistence ID are serialized—each persist awaits the previous one—so journal order matches emission order.
3. Only after the persist succeeds is `handleEvent(_:)` applied to live state. A failed persist rolls the sequence number back and rethrows: the actor never applies an event that didn't reach the journal.
4. **A persist failure is sticky.** Once a persist fails, every later emit for that persistence ID fails too—without attempting a write—because the journal can no longer be trusted (the failed write may actually have landed, with its acknowledgement lost). What to do next is the caller's decision; the recovery path is to drop the actor (its ID resigning clears the journal chain) and re-`register`, which replays the journal and re-syncs state from it.

`register(actor:with:)` (called in `init`) restores the actor before it serves calls: if a snapshot store is configured and holds a decodable snapshot, its state and covered sequence number are adopted directly, then only the events after it are folded through the same `handleEvent(_:)`—otherwise the whole journal is replayed, counting the sequence number up as it goes. After registration the actor is current and further `emit`s continue the sequence. Registering the same actor twice throws `RegistrationError.alreadyRegistered`; emitting on an unregistered actor throws `RegistrationError.notRegistered`.

Access the journal from anywhere via the system:

```swift
system.journal  // the installed ClusterJournalPlugin
```

## Snapshotting

Replaying a long journal on every activation gets expensive. Snapshotting checkpoints `state` every Nth event so recovery folds only the tail. Snapshots live in a **separate store**—the event store holds the event log and nothing else:

```swift
let system = await ClusterSystem("my-node") {
  $0.plugins.install(plugin: ClusterSingletonPlugin())
  $0.plugins.install(
    plugin: ClusterJournalPlugin(
      factory: { _ in PostgresEventStore() },
      snapshotFactory: { _ in PostgresSnapshotStore() }  // optional
    )
  )
}
```

All persistent state must live behind the `state` property—snapshots are taken from and restored into it (transient state can use separate properties outside):

```swift
@EventSourced
distributed actor OrderActor {

  struct State: Codable, Sendable {
    var items: [Item: Int] = [:]
  }

  var state: State = .init()

  // Snapshot cadence is a property of the entity type, declared in code so
  // the policy travels with it across nodes. Defaults to .disabled.
  let snapshotting: Snapshotting = .enabled(every: 100)

  // ... Event, handleEvent, init as before — nothing else changes
}
```

With `.enabled(every: N)`, each `emit` whose sequence number is a multiple of N saves a snapshot of the post-event state. Implement `SnapshotStore` to store them:

```swift
protocol SnapshotStore: Sendable {
  func save<State: Codable & Sendable>(
    _ state: State, id: PersistenceID, coveredSequenceNumber: Int64
  ) async throws
  func latestSnapshot<State: Codable & Sendable>(
    id: PersistenceID
  ) async throws -> Snapshot<State>?
}
```

Contract, in brief:

- **Monotonic per ID.** Re-saving the same `coveredSequenceNumber` is a no-op; a lower one is ignored (racing actor incarnations may save out of order). `latestSnapshot` returns the highest covered.
- **Tolerant decode.** A snapshot that no longer decodes after a `State` schema change is treated as absent—the journal falls back to full replay rather than failing.
- **Encoding is the store's business**, as with events.
- **Retention is store-internal**—keep the latest, or keep N for forensics.

Snapshotting never enters the failure semantics:

- A failed snapshot **save** is logged and journaling continues (compare Akka's `SnapshotFailed`)—the next cadence boundary tries again.
- `.enabled` with **no snapshot store configured** degrades the same way: a warning at each cadence boundary, journaling unaffected.
- A snapshot that fails to **load** falls back to full replay. The journal is always the source of truth; snapshots only shorten recovery.
- Mixed clusters are fine—one node `.enabled`, another `.disabled`, or different cadences only change snapshot density, never outcomes.

## Notes and caveats

- **Failure semantics are deliberately minimal.** Persist failures propagate to the caller and freeze writes for that persistence ID (see point 4 above); there is no built-in retry, backoff, or automatic replay-on-failure. This model is a placeholder by design and will be revisited—expect the failure/recovery API to evolve.
- **Replay cost is tunable, not zero.** Without snapshots, recovery replays the entire journal on every activation; `.enabled(every:)` bounds it to the tail after the latest snapshot.
- **Events are forever.** A journal is an append-only log of `Codable` events—evolve event types additively, or version them in your store's decoding.
- **`emit` is local.** It requires the actor instance (`whenLocal`); remote callers go through distributed methods that emit on the hosting node.
- **Lifecycle is managed.** The journal drops an actor's registration when its ID resigns, and refuses emits/restores after the plugin stops (failing loudly with `CancellationError` rather than crashing on shutdown races).

## Installation

```swift
dependencies: [
  .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "main")
]
```

Requires Swift 6.2+, macOS 26 / iOS 26 / tvOS 26 / watchOS 26 (Linux supported), and tracks `main` of [swift-distributed-actors](https://github.com/apple/swift-distributed-actors).

## See also

- [cluster-virtual-actors](https://github.com/akbashev/cluster-virtual-actors)—virtual actors with cluster placement and lifecycle; pair with `@EventSourced` for durable virtual actors.
- [distributed-actors-showcase](https://github.com/akbashev/distributed-actors-showcase)—example applications.
