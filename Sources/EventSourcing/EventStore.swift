public protocol EventStore {
    func persistEvent<Event: Codable>(_ event: Event, id: PersistenceID) async throws
    func eventsFor<Event: Codable>(id: PersistenceID) async throws -> [Event]
}
