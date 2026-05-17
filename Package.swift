// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Mani",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ManiCore", targets: ["ManiCore"]),
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
    ]
)
