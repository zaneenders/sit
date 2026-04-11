// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "sit",
  products: [
    .library(name: "Sit", targets: ["Sit"])
  ],
  targets: [
    .target(
      name: "Sit",
      dependencies: [],
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
