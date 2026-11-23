// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DroidBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DroidBridge", targets: ["DroidBridge"]),
        .executable(name: "DroidBridgeSupervisor", targets: ["DroidBridgeSupervisor"]),
        .executable(name: "DroidBridgeAvailability", targets: ["DroidBridgeAvailability"]),
        .executable(name: "DroidBridgeCompanionBroker", targets: ["DroidBridgeCompanionBroker"]),
    ],
    targets: [
        .executableTarget(name: "DroidBridgeSupervisor"),
        .target(name: "DroidBridgeCore"),
        .target(name: "AnonymousUsage"),
        .executableTarget(name: "DroidBridgeAvailability", dependencies: ["DroidBridgeCore"]),
        .executableTarget(name: "DroidBridgeCompanionBroker", dependencies: ["DroidBridgeCore"]),
        .target(name: "DroidBridgeStreaming", dependencies: ["DroidBridgeCore"]),
        .executableTarget(name: "DroidBridge", dependencies: ["DroidBridgeCore", "DroidBridgeStreaming", "AnonymousUsage"]),
        .testTarget(name: "AnonymousUsageTests", dependencies: ["AnonymousUsage"]),
        .testTarget(name: "DroidBridgeCoreTests", dependencies: ["DroidBridgeCore", "DroidBridgeStreaming"]),
    ]
)
