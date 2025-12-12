// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "sit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Sit", targets: ["Sit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-log.git", branch: "main"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", branch: "main"),
  ],
  targets: [
    .target(
      name: "Sit",
      dependencies: [
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ]
    ),
    .testTarget(
      name: "SitTests",
      dependencies: ["Sit"]),
  ]
)
