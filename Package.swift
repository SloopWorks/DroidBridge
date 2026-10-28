// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DroidBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DroidBridge", targets: ["DroidBridge"]),
        .executable(name: "DroidBridgeSupervisor", targets: ["DroidBridgeSupervisor"]),
    ],
    targets: [
        .executableTarget(name: "DroidBridgeSupervisor"),
        .target(name: "DroidBridgeCore"),
        .target(name: "DroidBridgeStreaming", dependencies: ["DroidBridgeCore"]),
        .executableTarget(name: "DroidBridge", dependencies: ["DroidBridgeCore", "DroidBridgeStreaming"]),
        .testTarget(name: "DroidBridgeCoreTests", dependencies: ["DroidBridgeCore", "DroidBridgeStreaming"]),
    ]
)
