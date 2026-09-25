// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VibeScribe",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "VibeScribeCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "VibeScribe",
            dependencies: ["VibeScribeCore"],
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "VibeScribeScreenshots",
            dependencies: ["VibeScribeCore"],
            path: "Tools/VibeScribeScreenshots"
        ),
        .executableTarget(
            name: "VibeScribeTests",
            dependencies: [
                "VibeScribeCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Tests/VibeScribeTests"
        ),
    ]
)
