// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "CueCore",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "CueCore", targets: ["CueCore"])
  ],
  targets: [
    .target(name: "CueCore"),
    .testTarget(
      name: "CueCoreTests",
      dependencies: ["CueCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
