import Distributed
import DistributedCluster

/**
 This is a starting point to create some Event Sourcing with actors, thus very rudimentary.

 References:
 1. https://doc.akka.io/docs/akka/current/typed/persistence.html
 2. https://doc.akka.io/docs/akka/current/persistence.html
 3. https://learn.microsoft.com/en-us/dotnet/orleans/grains/grain-persistence/?pivots=orleans-7-0
 4. https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing
 */

public typealias PersistenceID = String

public protocol EventSourced: DistributedActor where ActorSystem == ClusterSystem {
  associatedtype Event: Codable & Sendable
  distributed var persistenceID: PersistenceID { get }

  func handleEvent(_ event: Event)
}
