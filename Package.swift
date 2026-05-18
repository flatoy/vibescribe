// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VibeScribe",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .target(
            name: "VibeScribeCore"
        ),
        .executableTarget(
            name: "VibeScribe",
            dependencies: ["VibeScribeCore"]
        ),
        .executableTarget(
            name: "VibeScribeTests",
            dependencies: ["VibeScribeCore"],
            path: "Tests/VibeScribeTests"
        ),
    ]
)
