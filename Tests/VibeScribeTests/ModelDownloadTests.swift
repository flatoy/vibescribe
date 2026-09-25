import CryptoKit
import Foundation
@testable import VibeScribeCore

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    func record(_ value: Int64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
func runModelDownloadTests(_ t: TestHarness) async {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let manifestURL = root.appendingPathComponent("scripts/whisper_model_manifest.json")

    t.run("model manifest pins a complete remote download") {
        let manifest = try WhisperModelManifest.load(from: manifestURL)
        t.expectEqual(manifest.files.count, 19)
        t.expect(manifest.totalBytes > 600_000_000)
        t.expect(manifest.files.contains { $0.path == "tokenizer.json" })
        for entry in manifest.files {
            let url = try manifest.remoteURL(for: entry)
            t.expectEqual(url.host, "huggingface.co")
        }
    }

    t.run("turbo manifest pins a complete remote download") {
        let manifest = try WhisperModelManifest.load(from: root.appendingPathComponent("scripts/whisper_model_manifest_turbo.json"))
        t.expect(manifest.totalBytes > 600_000_000)
        t.expect(manifest.files.contains { $0.path == "TextDecoder.mlmodelc/weights/weight.bin" })
        t.expect(manifest.files.contains { $0.path == "tokenizer.json" })
        t.expect(manifest.files.allSatisfy { $0.source != "model" || $0.sourcePath.hasPrefix("openai_whisper-large-v3-v20240930_turbo_632MB/") })
    }

    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeScribeModelTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = Data("speech model".utf8)
    let checksum = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    let entry = WhisperModelManifest.Entry(
        source: "test",
        sourcePath: "test.bin",
        path: "weights/test.bin",
        size: Int64(original.count),
        sha256: checksum
    )
    let manifest = WhisperModelManifest(sources: [:], files: [entry])
    let destination = manifest.localURL(for: entry, in: folder)
    let downloader = WhisperModelDownloader(manifest: manifest, folder: folder)

    let missing = await downloader.inspect()
    t.run("missing model file requires a download") {
        t.expectEqual(missing.completedBytes, 0)
        t.expectEqual(missing.missing.count, 1)
    }

    t.run("verified model file is reused on later launches") {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: destination)
        t.expect(WhisperModelFileVerification.isValid(destination, for: entry))
    }
    let cached = await downloader.inspect()
    t.run("cached model is complete") {
        t.expectEqual(cached.completedBytes, entry.size)
        t.expect(cached.missing.isEmpty)
    }

    t.run("same-size corrupted model file is rejected") {
        try Data("speech modeL".utf8).write(to: destination)
        t.expect(!WhisperModelFileVerification.isValid(destination, for: entry))
    }
}

@MainActor
func runRemoteModelDownloadSmoke(_ t: TestHarness) async {
    do {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try WhisperModelManifest.load(
            from: root.appendingPathComponent("scripts/whisper_model_manifest.json")
        )
        guard let tokenizer = manifest.files.first(where: { $0.path == "tokenizer.json" }) else {
            throw WhisperModelDownloadError.invalidManifest
        }
        let sampleManifest = WhisperModelManifest(sources: manifest.sources, files: [tokenizer])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeScribeDownloadSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let downloader = WhisperModelDownloader(manifest: sampleManifest, folder: folder)
        let missing = await downloader.inspect()
        let progress = DownloadProgressRecorder()
        try await downloader.downloadMissing(missing) { completed, _ in
            progress.record(completed)
        }
        let complete = await downloader.inspect()
        t.run("remote model file downloads with progress and passes verification") {
            t.expectEqual(complete.completedBytes, tokenizer.size)
            t.expect(complete.missing.isEmpty)
            let values = progress.snapshot()
            print("  Download progress events: \(values.count); first: \(values.prefix(5))")
            t.expect(values.contains { $0 > 0 && $0 < tokenizer.size }, "Expected an in-flight progress update")
            t.expectEqual(values.last, tokenizer.size)
        }
    } catch {
        t.run("remote model file downloads with progress and passes verification") {
            throw error
        }
    }
}
