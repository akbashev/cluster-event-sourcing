// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let platforms: [SupportedPlatform]?
#if os(Linux)
platforms = nil
#else
platforms = [
    // we require the 'distributed actor' language and runtime feature:
    .iOS(.v16),
    .macOS(.v13),
    .tvOS(.v16),
    .watchOS(.v9),
]
#endif

let package = Package(
    name: "cluster-event-sourcing",
    platforms: platforms,
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "EventSourcing",
            targets: ["EventSourcing"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/akbashev/swift-distributed-actors",
            branch: "plugin_lifecycle_hook"
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "EventSourcing",
            dependencies: [
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
            ]
        ),
        .testTarget(
            name: "EventSourcingTests",
            dependencies: [
                "EventSourcing",
                .product(name: "DistributedCluster", package: "swift-distributed-actors")
            ]
        ),
    ]
)
