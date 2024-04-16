import Distributed
import DistributedCluster

/// Here magic should happen
public actor ClusterJournalPlugin {
    
    private var actorSystem: ClusterSystem!
    private var store: AnyEventStore!
    
    private var factory: (ClusterSystem) async throws -> (any EventStore)
    private var emitContinuations: [PersistenceID: [CheckedContinuation<Void, Never>]] = [:]
    private var restoringActorTasks: [PersistenceID: Task<Void, Never>] = [:]
    
    public func emit<E: Codable>(_ event: E, id persistenceId: PersistenceID) async throws {
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
        self.restoringActorTasks[persistenceId] = Task { [weak actor, weak self] in
            defer { Task { [weak self] in await self?.removeTaskFor(id: persistenceId) } }
            do {
                let events: [A.Event] = (try await self?.store.eventsFor(id: persistenceId)) ?? []
                await actor?.whenLocal { myself in
                    for event in events {
                        myself.handleEvent(event)
                    }
                }
            } catch {
                await self?.actorSystem.log.error(
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
        factory: @escaping (ClusterSystem) -> any EventStore
    ) {
        self.factory = factory
    }
}

extension ClusterJournalPlugin: _Plugin {
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
}

extension ClusterJournalPlugin: PluginActorLifecycleHook {
    nonisolated public func actorReady<Act>(_ actor: Act) where Act : DistributedActor, Act.ID == DistributedCluster.ClusterSystem.ActorID {
        guard let eventSourced = actor as? (any EventSourced) else { return }
        Task { [weak eventSourced] in
          await eventSourced?.whenLocal { [weak self] myself in
            await self?.restoreEventsFor(actor: myself, id: myself.persistenceId)
          }
        }
    }
    
    nonisolated public func resignID(_ id: DistributedCluster.ClusterSystem.ActorID) {
        //
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
    public func emit(event: Event) async throws {
        try await self.whenLocal { [weak self] myself in
            try await self?.actorSystem.journal.emit(event, id: myself.persistenceId)
            myself.handleEvent(event)
        }
    }
}

/// Not sure if it's correct way, basically wrapping `any EventStore` into `AnyEventStore` which is singleton
distributed actor AnyEventStore: EventStore, ClusterSingleton {
    
    private var store: any EventStore
    
    distributed func persistEvent<Event: Codable>(_ event: Event, id: PersistenceID) async throws {
        try await store.persistEvent(event, id: id)
    }
    
    distributed func eventsFor<Event: Codable>(id: PersistenceID) async throws -> [Event] {
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
