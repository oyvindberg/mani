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
        .testTarget(name: "ManiCoreTests", dependencies: ["ManiCore"]),
        .executableTarget(name: "PTYSpike", path: "Spikes/PTYSpike"),
    ]
)
