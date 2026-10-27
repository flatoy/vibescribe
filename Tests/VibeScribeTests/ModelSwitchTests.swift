import AVFoundation
import CryptoKit
import Foundation
@testable import VibeScribeCore

/// Holds a fake model's load until the test lets it finish.
private final class LoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

private struct FakeLoadError: LocalizedError {
    var errorDescription: String? { "The model could not load." }
}

/// Transcribes everything as its model's name.
private actor FakeEngine: SpeechEngine {
    enum Load {
        case immediate
        case gated(LoadGate)
        case fails
    }

    let id: SpeechModelID
    let load: Load

    init(id: SpeechModelID, load: Load) {
        self.id = id
        self.load = load
    }

    func prepare() async throws {
        switch load {
        case .immediate: return
        case .gated(let gate): await gate.wait()
        case .fails: throw FakeLoadError()
        }
    }

    func transcribe(segments: [AudioSegment], language: WhisperLanguage, vocabulary: String) async throws -> EngineResult {
        EngineResult(text: id.rawValue, language: "en")
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// What the installed model writes for a short recording.
private func dictate(_ client: WhisperKitClient) async -> String? {
    do {
        try client.start(language: .english)
    } catch {
        return nil
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
    buffer.frameLength = 1_600
    client.sendAudio(buffer: buffer)
    let outcome = await withCheckedContinuation { continuation in
        client.finish { continuation.resume(returning: $0) }
    }
    if case .success(let text, _) = outcome { return text }
    return nil
}

@MainActor
func runModelSwitchTests(_ t: TestHarness) async {
    let suite = "VibeScribeModelSwitchTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("VibeScribeModelSwitch-\(UUID().uuidString)", isDirectory: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    do {
        // Each model is one small verified file, so setup gets through verification quickly.
        let weights = Data("weights".utf8)
        let checksum = SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()
        for id in SpeechModelID.allCases {
            let folder = root.appendingPathComponent(id.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try weights.write(to: folder.appendingPathComponent("weights.bin"))
            let manifest = """
            {"sources": {"test": {"repo": "test/test", "revision": "main"}},
             "files": [{"source": "test", "sourcePath": "weights.bin", "path": "weights.bin", "size": \(weights.count), "sha256": "\(checksum)"}]}
            """
            try Data(manifest.utf8).write(to: root.appendingPathComponent("\(id.rawValue).json"))
        }
    } catch {
        t.run("model switch fixtures") { throw error }
        return
    }

    var loads: [SpeechModelID: FakeEngine.Load] = [:]
    let preferences = Preferences(defaults: defaults)
    preferences.speechModel = .largeV3
    let client = WhisperKitClient()
    let models = SpeechModelLibrary(
        preferences: preferences,
        logger: Logger(),
        client: client,
        folder: { root.appendingPathComponent($0.rawValue, isDirectory: true) },
        manifest: { root.appendingPathComponent("\($0.rawValue).json") },
        makeEngine: { id, _ in FakeEngine(id: id, load: loads[id] ?? .immediate) }
    )

    models.start()
    let launched = await waitUntil { models.active.isReady }
    let launchText = await dictate(client)
    t.run("the saved model loads at launch") {
        t.expect(launched, "large-v3 never became ready")
        t.expectEqual(launchText, "largeV3")
    }

    let turboGate = LoadGate()
    loads[.largeV3Turbo] = .gated(turboGate)
    models.switchTo(.largeV3Turbo)
    let turboLoading = await waitUntil { models.setup(for: .largeV3Turbo).state == .preparing }
    let duringSwitch = await dictate(client)
    t.run("dictation keeps using the current model while another one loads") {
        t.expect(turboLoading, "turbo never started loading")
        t.expectEqual(models.activeID, .largeV3)
        t.expectEqual(models.pendingID, .largeV3Turbo)
        t.expect(models.active.isReady)
        t.expectEqual(duringSwitch, "largeV3")
    }

    models.switchTo(.largeV3)
    turboGate.open()
    let abandonedFinished = await waitUntil { models.setup(for: .largeV3Turbo).state == .ready }
    let afterAbandon = await dictate(client)
    t.run("switching back drops the load that hadn't finished") {
        t.expect(abandonedFinished, "turbo's load never finished")
        t.expectEqual(models.activeID, .largeV3)
        t.expectNil(models.pendingID)
        t.expectEqual(preferences.speechModel, .largeV3)
        t.expectEqual(afterAbandon, "largeV3")
    }

    loads[.largeV3Turbo] = .immediate
    models.switchTo(.largeV3Turbo)
    let switched = await waitUntil { models.activeID == .largeV3Turbo }
    let afterSwitch = await dictate(client)
    t.run("the new model takes over once it has loaded") {
        t.expect(switched, "turbo never became active")
        t.expectNil(models.pendingID)
        t.expectEqual(preferences.speechModel, .largeV3Turbo)
        t.expectEqual(afterSwitch, "largeV3Turbo")
    }

    let barkGate = LoadGate()
    loads[.barkPlus] = .gated(barkGate)
    models.switchTo(.barkPlus)
    let barkLoading = await waitUntil { models.setup(for: .barkPlus).state == .preparing }
    models.setup(for: .barkPlus).cancel()
    barkGate.open()
    let barkSettled = await waitUntil { models.setup(for: .barkPlus).state != .preparing }
    let afterCancel = await dictate(client)
    t.run("cancelling the next model's setup ends the switch") {
        t.expect(barkLoading, "Bark never started loading")
        t.expect(barkSettled)
        t.expectNil(models.pendingID)
        t.expectEqual(models.activeID, .largeV3Turbo)
        t.expectEqual(afterCancel, "largeV3Turbo")
    }

    loads[.largeV3] = .fails
    models.switchTo(.largeV3)
    let failed = await waitUntil {
        if case .failed = models.setup(for: .largeV3).state { return true }
        return false
    }
    let afterFailure = await dictate(client)
    t.run("a model that fails to load leaves dictation on the current one") {
        t.expect(failed, "large-v3 never reported the failure")
        t.expectEqual(models.activeID, .largeV3Turbo)
        t.expectNil(models.pendingID)
        t.expectEqual(afterFailure, "largeV3Turbo")
    }
}

/// Dictation while switching from large-v3 turbo to a model that still has to compile for this Mac.
/// Pass a copy of the target model in a new folder so Core ML has nothing cached for it.
@MainActor
func runModelSwitchSmoke(_ t: TestHarness, current: String, target: SpeechModelID, compiling: String, audioPath: String) async {
    let suite = "VibeScribeModelSwitchSmoke-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let startedAt = ProcessInfo.processInfo.systemUptime
    func elapsed() -> String { String(format: "%.1fs", ProcessInfo.processInfo.systemUptime - startedAt) }
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let preferences = Preferences(defaults: defaults)
    preferences.speechModel = .largeV3Turbo
    let client = WhisperKitClient()
    let models = SpeechModelLibrary(
        preferences: preferences,
        logger: Logger(),
        client: client,
        folder: { URL(fileURLWithPath: $0 == .largeV3Turbo ? current : $0 == target ? compiling : "/nonexistent", isDirectory: true) },
        manifest: { root.appendingPathComponent("scripts/\($0.manifestName)") }
    )

    func dictateFile() async throws -> TranscriptionOutcome {
        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        try client.start(language: .english)
        while audioFile.framePosition < audioFile.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 4096)!
            try audioFile.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            client.sendAudio(buffer: buffer)
        }
        return await withCheckedContinuation { continuation in
            client.finish { continuation.resume(returning: $0) }
        }
    }

    do {
        models.start()
        while !models.active.isReady {
            if case .failed(let message) = models.activeState { throw TestFailure(message: message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("  large-v3 turbo ready at \(elapsed())")

        models.switchTo(target)
        var rounds: [(String, TimeInterval, TranscriptionOutcome)] = []
        for _ in 1...3 {
            try await Task.sleep(for: .seconds(10))
            let began = ProcessInfo.processInfo.systemUptime
            let outcome = try await dictateFile()
            rounds.append((elapsed(), ProcessInfo.processInfo.systemUptime - began, outcome))
        }
        let stillLoading = models.pendingID == target
        t.run("dictation keeps working while the next model compiles") {
            t.expect(stillLoading, "\(target.shortName) finished loading before the rounds were over; use an uncompiled copy")
            for (at, took, outcome) in rounds {
                print("  at \(at), took \(String(format: "%.1fs", took)): \(outcome)")
                guard case .success(let text, _) = outcome, !text.isEmpty else {
                    t.expect(false, "Expected a transcript, got \(outcome)")
                    continue
                }
                t.expect(took < 10, "Transcription waited for the compile")
            }
        }

        while models.activeID != target {
            if case .failed(let message) = models.setup(for: target).state { throw TestFailure(message: message) }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("  \(target.shortName) took over at \(elapsed())")
        let outcome = try await dictateFile()
        t.run("the compiled model takes over") {
            print("  \(outcome)")
            guard case .success(let text, _) = outcome else {
                t.expect(false, "Expected a transcript, got \(outcome)")
                return
            }
            t.expect(!text.isEmpty)
        }
    } catch {
        t.run("model switch smoke") { throw error }
    }
}
