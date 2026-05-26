// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mani",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ManiCore", targets: ["ManiCore"]),
        // v0.2 protocol transport. Embeds an HTTP→WebSocket server,
        // an EventBus that broadcasts ManiCore Events with monotonic
        // sequence numbers, and the wire envelopes the mac app + any
        // remote client (Android) speak.
        .library(name: "ManiServer", targets: ["ManiServer"]),
    ],
    dependencies: [
        // swift-nio backs ManiServer's WebSocket transport. Will also
        // be used by WebSocketSpike for protocol-level validation.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "ManiCore"),
        .testTarget(
            name: "ManiCoreTests",
            dependencies: ["ManiCore"],
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "ManiServer",
            dependencies: [
                "ManiCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "ManiServerTests",
            dependencies: ["ManiServer"]
        ),
        .executableTarget(
            name: "mani-agent",
            dependencies: ["ManiCore"],
            path: "Sources/mani-agent"
        ),
        .executableTarget(name: "PTYSpike", path: "Spikes/PTYSpike"),
        .executableTarget(name: "HookShim", path: "Spikes/HookSpike/HookShim"),
        .executableTarget(name: "HookListener", path: "Spikes/HookSpike/HookListener"),
        .executableTarget(name: "JSONLSpike", path: "Spikes/JSONLSpike"),
        .executableTarget(name: "CrashSpike", dependencies: ["ManiCore"], path: "Spikes/CrashSpike"),
        .executableTarget(name: "WatcherSpike", path: "Spikes/WatcherSpike"),
        .executableTarget(
            name: "WebSocketSpike",
            dependencies: ["ManiServer"],
            path: "Spikes/WebSocketSpike"
        ),
    ]
)
