// swift-tools-version: 5.9
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(name: "Eveil2", platforms: [.macOS(.v14)], products: [
    .executable(name: "Eveil2", targets: ["EveilApp"]),
    .executable(name: "Eveil2Daemon", targets: ["EveilService"])
], targets: [
    .target(name: "EveilIPC"),
    .target(name: "EveilCore", dependencies: ["EveilIPC"]),
    .executableTarget(name: "EveilService", dependencies: ["EveilIPC", "EveilCore"], linkerSettings: [
        .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", root + "/Resources/Daemon-Info.plist"])
    ]),
    .executableTarget(name: "EveilApp", dependencies: ["EveilIPC", "EveilCore"]),
    .testTarget(name: "EveilAppTests", dependencies: ["EveilApp", "EveilIPC"]),
    .testTarget(name: "EveilIPCTests", dependencies: ["EveilIPC"]),
    .testTarget(name: "EveilCoreTests", dependencies: ["EveilCore", "EveilIPC"])
])
