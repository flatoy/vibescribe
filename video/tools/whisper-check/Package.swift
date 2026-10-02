// swift-tools-version: 6.2
// Standalone verifier for the film's voice clips: transcribes them with the same
// WhisperKit version, model files and decode options the app uses, so the on-screen
// "Pasted N words" counts are checked against VibeScribe's real engine.
// Separate package on purpose: it never touches the app's Package.swift.
import PackageDescription

let package = Package(
    name: "whisper-check",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "whisper-check",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
    ]
)
