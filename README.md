# Cluster System Event Sourcing

An event sourcing framework implementation for Swift distributed [Cluster System](https://github.com/apple/swift-distributed-actors).

## Usage

### Documentation: TODO

1. Currently there is no default store providers, so you need to create one and conform to `EventStore` protocol. This could be any class, actor and etc.
2. Install plugins. `ClusterJournalPlugin` wraps store into singleton, so singleton plugin also should be added (and order is important!).
```swift
let node = await ClusterSystem("simple-node") {
    $0.plugins.install(plugin: ClusterSingletonPlugin())
    $0.plugins.install(
        plugin: ClusterJournalPlugin { _ in
            SomeStore()
        }
    )
}
```

3. Make distributed actor `EventSourced`. Provide `persistenceID` and define the `handleEvent(_:)` function:
```swift
distributed actor SomeActor: EventSourced {

    // Some custom events for actor
    enum Event {
        case doSomething 
    }
    
    // This is important to provide, events are stored per actor using persistenceID
    distributed var persistenceID: PersistenceID { "some-actor" }
    
    distributed func doSomething() async throws {
        try await self.emit(event: .doSomething)
    }
    
    distributed func handleEvent(_ event: Event) { 
        switch event {
        case .doSomething:
            // update state
        }
    }
    
    init(actorSystem: ClusterSystem) {
        self.actorSystem = actorSystem
    }
}
```
