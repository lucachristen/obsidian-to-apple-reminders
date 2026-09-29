// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemindersBridge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RemindersBridge", targets: ["RemindersBridge"])],
    targets: [
        .target(name: "BridgeCore"),
        .executableTarget(name: "RemindersBridge", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
    ]
)
