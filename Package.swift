// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "releasy-sender",
  platforms: [.iOS(.v17), .macOS(.v10_15), .visionOS(.v1)],
  products: [
    .library(name: "ReleasySender", targets: ["ReleasySender"])
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies.git", .upToNextMajor(from: "1.17.2")),
  ],
  targets: [
    .target(
      name: "ReleasySender",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies")
      ],
      path: "Sources"
    ),
    // Tests
    .testTarget(
      name: "ReleasySenderTests",
      dependencies: ["ReleasySender"],
      path: "Tests"
    )
  ]
)
