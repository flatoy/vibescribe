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
    private static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func modelFolder(for model: SpeechModelID = .largeV3) -> URL {
        if !isAppBundle {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/\(model.developmentFolderName)", isDirectory: true)
        }
        return supportFolder().appendingPathComponent(model.folderName, isDirectory: true)
    }

    static func manifestURL(for model: SpeechModelID = .largeV3) -> URL {
        if isAppBundle {
            return Bundle.main.resourceURL!.appendingPathComponent(model.manifestName)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/\(model.manifestName)")
    }

    /// Application Support folder for the app's own data.
    static func supportFolder() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = isAppBundle ? (Bundle.main.bundleIdentifier ?? "VibeScribe") : "VibeScribe-Development"
        return support.appendingPathComponent(name, isDirectory: true)
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
    private var engine: WhisperEngine?
    private var vocabulary = ""
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

    /// Switches to another downloaded model. Call `prepare()` afterwards.
    func use(modelFolder: URL) {
        lock.lock()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recording = nil
        activeID = nil
        engine = WhisperEngine(modelFolder: modelFolder)
        prepared = false
        preparationError = nil
        lock.unlock()
    }

    /// Names and jargon to prompt the decoder with, comma separated.
    func setVocabulary(_ words: String) {
        lock.lock()
        vocabulary = words
        lock.unlock()
    }

    func prepare() async throws {
        let engine = lock.withLock { self.engine }
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
        lock.lock()
        defer { lock.unlock() }
        guard engine != nil else { throw WhisperModelError.missing }
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
        let engine = self.engine
        let vocabulary = self.vocabulary
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
                let result = try await engine.transcribe(
                    samples: samples,
                    sampleRate: sampleRate,
                    language: language,
                    vocabulary: vocabulary
                )
                self?.complete(id: id, outcome: .success(result.text, language: result.language), onFinished: onFinished)
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

private struct EngineResult: Sendable {
    let text: String
    let language: String?
}

private actor WhisperEngine {
    private let modelFolder: URL
    private var model: WhisperKit?
    private var loadTask: Task<Void, Error>?
    private var lastTranscription: Task<EngineResult, Error>?

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

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        language: WhisperLanguage,
        vocabulary: String
    ) async throws -> EngineResult {
        let previous = lastTranscription
        let task = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await performTranscription(
                samples: samples,
                sampleRate: sampleRate,
                language: language,
                vocabulary: vocabulary
            )
        }
        lastTranscription = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performTranscription(
        samples: [Float],
        sampleRate: Double,
        language: WhisperLanguage,
        vocabulary: String
    ) async throws -> EngineResult {
        try await prepare()
        try Task.checkCancellation()
        let audio = try AudioBufferConverter.whisperSamples(from: samples, sampleRate: sampleRate)
        guard !audio.isEmpty, SpeechDetector.containsSpeech(audio, sampleRate: Double(WhisperKit.sampleRate)) else {
            return EngineResult(text: "", language: language.whisperCode)
        }
        guard let model else { throw WhisperModelError.missing }

        let options = DecodingOptions(
            language: language.whisperCode,
            detectLanguage: language == .automatic,
            withoutTimestamps: true,
            promptTokens: Self.promptTokens(for: vocabulary, tokenizer: model.tokenizer)
        )
        let results = try await model.transcribe(audioArray: audio, decodeOptions: options)
        try Task.checkCancellation()
        // Drop segments Whisper itself thinks are silence it filled in.
        let text = results
            .flatMap(\.segments)
            .filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1) }
            .map(\.text)
            .joined(separator: " ")
            .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed
        return EngineResult(text: text, language: results.first?.language ?? language.whisperCode)
    }

    /// Whisper treats the prompt as preceding text, so a word list nudges its spelling.
    private static func promptTokens(for vocabulary: String, tokenizer: WhisperTokenizer?) -> [Int]? {
        let words = vocabulary.trimmed
        guard !words.isEmpty, let tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + words)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
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
