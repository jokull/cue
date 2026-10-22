// swift-tools-version: 6.2
import PackageDescription

// Replays recorded realtime partials through CueCore's ScriptTracker to measure prompter lag.
let package = Package(
  name: "tracklag",
  platforms: [.macOS(.v26)],
  dependencies: [.package(path: "../../../Packages/CueCore")],
  targets: [.executableTarget(name: "tracklag", dependencies: ["CueCore"])]
)
