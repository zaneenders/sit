// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "sit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "Sit", targets: ["Sit"]),
    .executable(name: "sit", targets: ["sit-cli"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.13.0"),
  ],
  targets: [
    .target(
      name: "Sit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      swiftSettings: [
        .treatAllWarnings(as: .error),
        .enableExperimentalFeature("InternalImportsByDefault"),
      ]),
    .executableTarget(
      name: "sit-cli",
      dependencies: [
        .target(name: "Sit"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      path: "Sources/sit-cli",
      swiftSettings: [
        .treatAllWarnings(as: .error)
      ]),
    .testTarget(
      name: "SitTests",
      dependencies: [
        .byName(name: "Sit"),
        .target(name: "sit-cli"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      swiftSettings: [
        .treatAllWarnings(as: .error)
      ]),
  ]
)
