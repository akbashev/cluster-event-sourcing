import Distributed
import DistributedCluster

public actor ClusterJournalPlugin {

  private var actorSystem: ClusterSystem!
  private var store: AnyEventStore!

  private var factory: @Sendable (ClusterSystem) async throws -> (any EventStore)
  private var emitTasks: [PersistenceID: Task<Void, any Error>] = [:]
  private var registeredActors: [ClusterSystem.ActorID: PersistenceID] = [:]

  public enum RegistrationError: Error {
    case notRegistered(ClusterSystem.ActorID)
    case alreadyRegistered(ClusterSystem.ActorID, existingPersistenceID: PersistenceID)
  }

  public func emit<E: Codable & Sendable>(_ event: E, id: ClusterSystem.ActorID) async throws {
    guard let persistenceId = self.registeredActors[id] else {
      throw RegistrationError.notRegistered(id)
    }
    if let emitTask = self.emitTasks[persistenceId] { try await emitTask.value }

    let task = Task {
      defer { self.emitTasks[persistenceId] = nil }
      self.actorSystem.log.info("Emit event: \(event) for actor with id: \(persistenceId)")
      try await store.persistEvent(event, id: persistenceId)
    }
    self.emitTasks[persistenceId] = task
    return try await task.value
  }

  /// As we already checked whenLocal on `actorReady`—would be nice to have some type level understanding already here and not to double check...
  public func restoreEventsFor<A: EventSourced>(actor: A, id persistenceId: PersistenceID) async throws {
    let events: [A.Event] = try await self.store.eventsFor(id: persistenceId)
    self.actorSystem.log.info("Restoring events \(events) of an actor with id: \(persistenceId)")
    guard !Task.isCancelled else { return }
    await actor.whenLocal { myself in
      for event in events {
        guard !Task.isCancelled else { return }
        myself.handleEvent(event)
      }
    }
  }

  public func register<A: EventSourced>(actor: A, with persistentId: PersistenceID) async throws {
    if let existing = self.registeredActors[actor.id] {
      throw RegistrationError.alreadyRegistered(actor.id, existingPersistenceID: existing)
    }
    self.registeredActors[actor.id] = persistentId
    try await self.restoreEventsFor(actor: actor, id: persistentId)
  }

  fileprivate func removeActorWith(id: ClusterSystem.ActorID) {
    guard let persistenceId = self.registeredActors[id] else { return }
    self.emitTasks[persistenceId]?.cancel()
    self.emitTasks.removeValue(forKey: persistenceId)
    self.registeredActors.removeValue(forKey: id)
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
    self.store =
      try await system
      .singleton
      .host(name: "\(ClusterJournalPlugin.pluginKey)_store") {
        try await AnyEventStore(actorSystem: $0, store: self.factory($0))
      }
  }

  public func stop(_ system: ClusterSystem) async {
    self.actorSystem = nil
    self.store = nil
  }

  nonisolated public func onActorReady<Act: DistributedActor>(_ actor: Act) where Act.ID == ClusterSystem.ActorID {}

  nonisolated public func onResignID(_ id: DistributedCluster.ClusterSystem.ActorID) {
    Task.immediate { [weak self] in
      await self?.removeActorWith(id: id)
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
    try await self.whenLocal { local in
      try await self.actorSystem.journal.emit(event, id: local.id)
      local.handleEvent(event)
    }
  }
}

/// Not sure if it's correct way, basically wrapping `any EventStore` into `AnyEventStore` which is singleton
distributed actor AnyEventStore: EventStore, ClusterSingleton {

  private var store: any EventStore

  distributed func persistEvent<Event: Codable & Sendable>(_ event: Event, id: PersistenceID) async throws {
    try await self.store.persistEvent(event, id: id)
  }

  distributed func eventsFor<Event: Codable & Sendable>(id: PersistenceID) async throws -> [Event] {
    try await self.store.eventsFor(id: id)
  }

  init(
    actorSystem: ActorSystem,
    store: any EventStore
  ) {
    self.actorSystem = actorSystem
    self.store = store
  }
}
