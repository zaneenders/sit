// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "sit",
  products: [
    .library(name: "Sit", targets: ["Sit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
  ],
  targets: [
    .target(
      name: "Sit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("InternalImportsByDefault"),
      ]),
    .testTarget(
      name: "SitTests",
      dependencies: [
        .byName(name: "Sit")
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
      ]),
  ]
)
