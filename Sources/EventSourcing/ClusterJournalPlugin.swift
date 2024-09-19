import Distributed
import DistributedCluster

/// Here magic should happen
public actor ClusterJournalPlugin {
    
    private var actorSystem: ClusterSystem!
    private var store: AnyEventStore!
    
    private var factory: @Sendable (ClusterSystem) async throws -> (any EventStore)
    private var emitContinuations: [PersistenceID: [CheckedContinuation<Void, Never>]] = [:]
    private var restoringActorTasks: [PersistenceID: Task<Void, Never>] = [:]
    private var localActorChecks: [PersistenceID: Task<Void, Never>] = [:]
        
    public func emit<E: Codable & Sendable>(_ event: E, id persistenceId: PersistenceID) async throws {
        if self.restoringActorTasks[persistenceId] != .none {
            await withCheckedContinuation { continuation in
                self.emitContinuations[persistenceId, default: []].append(continuation)
            }
        }
        try await store.persistEvent(event, id: persistenceId)
    }
    
    /// As we already checked whenLocal on `actorReady`—would be nice to have some type level understanding already here and not to double check...
    public func restoreEventsFor<A: EventSourced>(actor: A, id persistenceId: PersistenceID) {
        /// Checking if actor is already in restoring state
        guard self.restoringActorTasks[persistenceId] == .none else { return }
        self.restoringActorTasks[persistenceId] = Task { [weak actor] in
            defer { self.removeTaskFor(id: persistenceId) }
            do {
                let events: [A.Event] = try await self.store.eventsFor(id: persistenceId)
                await actor?.whenLocal { myself in
                    for event in events {
                        myself.handleEvent(event)
                    }
                }
            } catch {
                self.actorSystem.log.error(
                    "Cluster journal haven't been able to restore state of an actor \(persistenceId), reason: \(error)"
                )
            }
        }
    }
    
    private func finishContinuationsFor(
        id: PersistenceID
    ) {
        for emit in (self.emitContinuations[id] ?? []) { emit.resume() }
        self.emitContinuations.removeValue(forKey: id)
    }
    
    private func removeTaskFor(id: PersistenceID) {
        self.restoringActorTasks.removeValue(forKey: id)
        self.finishContinuationsFor(id: id)
    }
    
    public init(
        factory: @Sendable @escaping (ClusterSystem) -> any EventStore
    ) {
        self.factory = factory
    }
}

extension ClusterJournalPlugin: ActorLifecyclePlugin {
    static let pluginKey: Key = "$clusterJournal"
    
    public nonisolated var key: Key {
        Self.pluginKey
    }
    
    public func start(_ system: ClusterSystem) async throws {
        self.actorSystem = system
        self.store = try await system
            .singleton
            .host(name: "\(ClusterJournalPlugin.pluginKey)_store") {
                try await AnyEventStore(actorSystem: $0, store: self.factory($0))
            }
    }
    
    public func stop(_ system: ClusterSystem) async {
        self.actorSystem = nil
        self.store = nil
        for task in self.restoringActorTasks.values { task.cancel() }
        for emit in self.emitContinuations.values.flatMap({ $0 }) { emit.resume() }
        self.emitContinuations.removeAll()
    }
    
    nonisolated public func onActorReady<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {
        Task { await self.checkActor(actor) }
    }
    
    nonisolated public func onResignID(_ id: DistributedCluster.ClusterSystem.ActorID) {
        //
    }
    
    private func checkActor<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {
        guard let eventSourced = actor as? (any EventSourced) else { return }
        guard let id = eventSourced.id.metadata.persistenceID else {
            fatalError("Persistence ID is not defined, please do it by defining an @ActorID.Metadata(\\.persistenceID) property")
        }
        guard self.localActorChecks[id] == .none else { return }
        self.localActorChecks[id] = Task { [weak eventSourced] in
            defer { self.localActorChecks.removeValue(forKey: id) }
            await eventSourced?.whenLocal { [weak self] myself in
                await self?.restoreEventsFor(actor: myself, id: id)
            }
        }
    }
}

extension ClusterSystem {
    
    public var journal: ClusterJournalPlugin {
        let key = ClusterJournalPlugin.pluginKey
        guard let journalPlugin = self.settings.plugins[key] else {
            fatalError("No plugin found for key: [\(key)], installed plugins: \(self.settings.plugins)")
        }
        return journalPlugin
    }
}


extension EventSourced {
    // `whenLocal` is async atm, ideally should be non-async 🤔
    public func emit(event: Event) async throws {
        guard let id = self.id.metadata.persistenceID else { return }
        try await self.whenLocal { [weak self] myself in
            try await self?.actorSystem.journal.emit(event, id: id)
            myself.handleEvent(event)
        }
    }
}

/// Not sure if it's correct way, basically wrapping `any EventStore` into `AnyEventStore` which is singleton
distributed actor AnyEventStore: EventStore, ClusterSingleton {
    
    private var store: any EventStore
    
    distributed func persistEvent<Event: Codable & Sendable>(_ event: Event, id: PersistenceID) async throws {
        try await store.persistEvent(event, id: id)
    }
    
    distributed func eventsFor<Event: Codable & Sendable>(id: PersistenceID) async throws -> [Event] {
        try await store.eventsFor(id: id)
    }
    
    init(
        actorSystem: ActorSystem,
        store: any EventStore
    ) {
        self.actorSystem = actorSystem
        self.store = store
    }
}
