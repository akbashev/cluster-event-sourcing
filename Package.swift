// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let platforms: [SupportedPlatform]?
#if os(Linux)
platforms = nil
#else
platforms = [
  // we require the 'distributed actor' language and runtime feature:
  .iOS(.v26),
  .macOS(.v26),
  .tvOS(.v26),
  .watchOS(.v26),
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
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"605.0.0"),
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .macro(
      name: "EventSourcingMacros",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "EventSourcing",
      dependencies: [
        "EventSourcingMacros",
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
      ]
    ),
    .testTarget(
      name: "EventSourcingTests",
      dependencies: [
        "EventSourcing",
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
      ]
    ),
    .testTarget(
      name: "EventSourcingMacrosTests",
      dependencies: [
        "EventSourcingMacros",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
  ]
)
