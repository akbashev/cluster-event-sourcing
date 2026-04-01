public protocol EventStore: Sendable {
  func persistEvent<Event: Codable & Sendable>(_ event: Event, id: String, sequenceNumber: Int64) async throws
  func eventsFor<Event: Codable & Sendable>(id: String) async throws -> [Event]
}
