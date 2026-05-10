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
    .package(url: "https://github.com/apple/swift-collections-benchmark.git", from: "0.0.4"),
  ],
  targets: [
    .target(
      name: "Sit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("InternalImportsByDefault"),
      ]),
    .executableTarget(
      name: "sit-cli",
      dependencies: [
        .target(name: "Sit"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "Sources/sit-cli",
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes")
      ]),
    .testTarget(
      name: "SitTests",
      dependencies: [
        .byName(name: "Sit"),
        .target(name: "sit-cli"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes")
      ]),
    .executableTarget(
      name: "SitBenchmarks",
      dependencies: [
        .byName(name: "Sit"),
        .product(name: "CollectionsBenchmark", package: "swift-collections-benchmark"),
      ],
      path: "Benchmarks/SitBenchmarks",
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .unsafeFlags(["-O"]),
      ]),
    .executableTarget(
      name: "BenchRunner",
      dependencies: [],
      path: "Benchmarks/BenchRunner",
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
      ]),
  ]
)
