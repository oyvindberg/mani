// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mani",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ManiCore", targets: ["ManiCore"]),
    ],
    dependencies: [
        // swift-nio is the v0.2 protocol's transport layer. Pulled in
        // by WebSocketSpike (S2) and will be lifted into the mac app
        // for the embedded mani-server when the spike pans out.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "ManiCore"),
        .testTarget(
            name: "ManiCoreTests",
            dependencies: ["ManiCore"],
            resources: [.copy("Fixtures")]
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
            dependencies: [
                "ManiCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "Spikes/WebSocketSpike"
        ),
    ]
)
