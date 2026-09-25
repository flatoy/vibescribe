import AVFoundation
import Foundation
import WhisperKit

enum WhisperModelError: LocalizedError {
    case missing
    case notReady
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The speech model is missing. Open VibeScribe to download it."
        case .notReady:
            return "The speech model is still being prepared. Open VibeScribe to check its progress."
        case .failed(let message):
            return "The local speech model could not load: \(message)"
        }
    }
}

enum WhisperModelLocator {
    static func modelFolder() -> URL {
        if Bundle.main.bundleURL.pathExtension != "app" {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/WhisperModel", isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "VibeScribe", isDirectory: true)
            .appendingPathComponent("WhisperModel-large-v3-v20240930_626MB", isDirectory: true)
    }

    static func manifestURL() -> URL {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.resourceURL!
                .appendingPathComponent("whisper_model_manifest.json")
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/whisper_model_manifest.json")
    }

    static func isComplete(_ folder: URL) -> Bool {
        let requiredFiles = [
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/weights/weight.bin",
            "tokenizer.json",
            "tokenizer_config.json",
        ]
        return requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }
}

private final class AudioRecording {
    let id = UUID()
    let language: WhisperLanguage
    var sampleRate: Double?
    var samples: [Float] = []
    var error: String?

    init(language: WhisperLanguage) {
        self.language = language
    }
}

final class WhisperKitClient: RecordingSessionTranscription, @unchecked Sendable {
    private let engine: WhisperEngine?
    private let onLog: @Sendable (String, LogLevel) -> Void
    private let lock = NSLock()
    private var recording: AudioRecording?
    private var activeID: UUID?
    private var transcriptionTask: Task<Void, Never>?
    private var preparationError: String?
    private var prepared = false

    init(modelFolder: URL?, onLog: @Sendable @escaping (String, LogLevel) -> Void) {
        self.engine = modelFolder.map(WhisperEngine.init(modelFolder:))
        self.onLog = onLog
    }

    func prepare() async throws {
        guard let engine else {
            onLog(WhisperModelError.missing.localizedDescription, .error)
            throw WhisperModelError.missing
        }
        do {
            try await engine.prepare()
            setPrepared()
            onLog("Offline WhisperKit model is ready.", .info)
        } catch {
            setPreparationError(error.localizedDescription)
            onLog("Local model failed to load: \(error.localizedDescription)", .error)
            throw error
        }
    }

    func start(language: WhisperLanguage) throws {
        guard engine != nil else { throw WhisperModelError.missing }
        lock.lock()
        defer { lock.unlock() }
        if let preparationError {
            throw WhisperModelError.failed(preparationError)
        }
        guard prepared else { throw WhisperModelError.notReady }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        let recording = AudioRecording(language: language)
        self.recording = recording
        activeID = recording.id
    }

    func sendAudio(buffer: AVAudioPCMBuffer) {
        let sampleRate = buffer.format.sampleRate
        let samples = AudioBufferConverter.monoSamples(from: buffer)

        lock.lock()
        defer { lock.unlock() }
        guard let recording else { return }
        guard let samples else {
            recording.error = "The microphone supplied an unsupported audio format."
            return
        }
        guard recording.error == nil else { return }
        if let priorRate = recording.sampleRate, priorRate != sampleRate {
            recording.error = "The microphone sample rate changed during recording."
            return
        }
        recording.sampleRate = sampleRate
        recording.samples.append(contentsOf: samples)
    }

    func finish(onFinished: @Sendable @escaping (TranscriptionOutcome) -> Void) {
        lock.lock()
        let recording = self.recording
        self.recording = nil
        lock.unlock()

        guard let recording, let engine else {
            onFinished(.failure(WhisperModelError.missing.localizedDescription))
            return
        }
        if let error = recording.error {
            complete(id: recording.id, outcome: .failure(error), onFinished: onFinished)
            return
        }
        let samples = recording.samples
        guard !samples.isEmpty else {
            complete(id: recording.id, outcome: .success(""), onFinished: onFinished)
            return
        }
        let sampleRate = recording.sampleRate ?? Double(WhisperKit.sampleRate)
        let language = recording.language
        let id = recording.id

        let task = Task { [weak self] in
            do {
                let text = try await engine.transcribe(samples: samples, sampleRate: sampleRate, language: language)
                self?.complete(id: id, outcome: .success(text), onFinished: onFinished)
            } catch {
                self?.complete(id: id, outcome: .failure(error.localizedDescription), onFinished: onFinished)
            }
        }

        lock.lock()
        if activeID == id {
            transcriptionTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        recording = nil
        activeID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        lock.unlock()
    }

    private func complete(
        id: UUID,
        outcome: TranscriptionOutcome,
        onFinished: @Sendable (TranscriptionOutcome) -> Void
    ) {
        lock.lock()
        let current = activeID == id
        if current {
            activeID = nil
            transcriptionTask = nil
        }
        lock.unlock()
        guard current else { return }
        onFinished(outcome)
    }

    private func setPreparationError(_ message: String) {
        lock.lock()
        prepared = false
        preparationError = message
        lock.unlock()
    }

    private func setPrepared() {
        lock.lock()
        prepared = true
        preparationError = nil
        lock.unlock()
    }
}

private actor WhisperEngine {
    private let modelFolder: URL
    private var model: WhisperKit?
    private var loadTask: Task<Void, Error>?
    private var lastTranscription: Task<String, Error>?

    init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    func prepare() async throws {
        if model != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }

        let task = Task { try await loadLocalModel() }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw error
        }
    }

    func transcribe(samples: [Float], sampleRate: Double, language: WhisperLanguage) async throws -> String {
        let previous = lastTranscription
        let task = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await performTranscription(samples: samples, sampleRate: sampleRate, language: language)
        }
        lastTranscription = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performTranscription(samples: [Float], sampleRate: Double, language: WhisperLanguage) async throws -> String {
        try await prepare()
        try Task.checkCancellation()
        let audio = try AudioBufferConverter.whisperSamples(from: samples, sampleRate: sampleRate)
        guard !audio.isEmpty else { return "" }
        guard let model else { throw WhisperModelError.missing }

        let options = DecodingOptions(
            language: language.whisperCode,
            detectLanguage: language == .automatic,
            withoutTimestamps: true
        )
        let results = try await model.transcribe(audioArray: audio, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmed
    }

    private func loadLocalModel() async throws {
        guard WhisperModelLocator.isComplete(modelFolder) else { throw WhisperModelError.missing }
        // Validate the local tokenizer first so WhisperKit never falls back to a Hub download.
        _ = try await AutoTokenizerWrapper.from(modelFolder: modelFolder)
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: modelFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        model = try await WhisperKit(config)
    }
}
