public protocol EventStore {
    func persistEvent<Event: Codable>(_ event: Event, id: String) async throws
    func eventsFor<Event: Codable>(id: String) async throws -> [Event]
}
