// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "sit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Sit", targets: ["Sit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-binary-parsing", branch: "0.0.1")
  ],
  targets: [
    .target(
      name: "Sit",
      dependencies: [
        .product(name: "BinaryParsing", package: "swift-binary-parsing")
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("LifetimeDependence"),
      ]),
    .testTarget(
      name: "SitTests",
      dependencies: [
        .byName(name: "Sit")
      ]),
  ]
)
