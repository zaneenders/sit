// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "sit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Sit", targets: ["Sit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
    .package(url: "https://github.com/apple/swift-collections.git", branch: "main"),
  ],
  targets: [
    .target(
      name: "Sit",
      dependencies: [
        .product(name: "Collections", package: "swift-collections"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "_NIOFileSystem", package: "swift-nio"),
      ]),
    .testTarget(name: "SitTests", dependencies: ["Sit"]),
  ]
)
