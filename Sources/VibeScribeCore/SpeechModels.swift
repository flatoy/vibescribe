import Combine
import Foundation

enum SpeechModelID: String, CaseIterable, Identifiable, Sendable {
    case largeV3
    case largeV3Turbo
    case barkPlus

    var id: String { rawValue }

    /// The models this Mac can run. Bark's encoder needs macOS 15.
    static var available: [SpeechModelID] {
        if #available(macOS 15, *) { return allCases }
        return allCases.filter { $0 != .barkPlus }
    }

    var name: String {
        switch self {
        case .largeV3: return "Whisper large-v3"
        case .largeV3Turbo: return "Whisper large-v3 turbo"
        case .barkPlus: return "Underdog Bark 3.0 Plus"
        }
    }

    var shortName: String {
        switch self {
        case .largeV3: return "large-v3"
        case .largeV3Turbo: return "large-v3 turbo"
        case .barkPlus: return "Bark 3.0 Plus"
        }
    }

    var systemImage: String {
        switch self {
        case .largeV3, .largeV3Turbo: return "waveform"
        case .barkPlus: return "dog.fill"
        }
    }

    var languages: String {
        switch self {
        case .largeV3, .largeV3Turbo: return "100 languages"
        case .barkPlus: return "English only"
        }
    }

    /// Average word error rate, in percent, across the Open ASR Leaderboard's seven English test sets. Lower is
    /// better. Whisper's are the leaderboard's scores for OpenAI's originals, of which the downloads are Argmax's
    /// compressed builds. Bark's is Underdog's, from the leaderboard's code.
    var wordErrorRate: Double {
        switch self {
        case .largeV3: return 6.04
        case .largeV3Turbo: return 6.58
        case .barkPlus: return 4.76
        }
    }

    /// Seconds to transcribe a minute of English speech on an M4 Pro MacBook Pro, the median of three runs from
    /// `swift run -c release -Xswiftc -enable-testing VibeScribeTests --benchmark <model> <folder> <audio>`.
    var secondsPerMinute: Double {
        switch self {
        case .largeV3: return 12.0
        case .largeV3Turbo: return 3.0
        case .barkPlus: return 0.6
        }
    }

    /// Bark writes short phrases without capitals or punctuation, so VibeScribe adds only a capital and a
    /// full stop. Longer speech is punctuated.
    var punctuatesShortPhrases: Bool { self != .barkPlus }

    /// Seconds Core ML takes to compile the model the first time it loads on an M4 Pro MacBook Pro.
    /// Later loads come from its cache and take a few seconds.
    var compileSeconds: Double {
        switch self {
        case .largeV3: return 17
        case .largeV3Turbo: return 50
        case .barkPlus: return 190
        }
    }

    var homepage: URL {
        switch self {
        case .largeV3: return URL(string: "https://huggingface.co/openai/whisper-large-v3")!
        case .largeV3Turbo: return URL(string: "https://huggingface.co/openai/whisper-large-v3-turbo")!
        case .barkPlus: return URL(string: "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Plus")!
        }
    }

    /// Bark understands only English, so the language picker and pinned languages don't apply to it.
    var isEnglishOnly: Bool { self == .barkPlus }

    /// Whisper reads the vocabulary as preceding text. Bark has nothing similar.
    var supportsVocabulary: Bool { self != .barkPlus }

    var folderName: String {
        switch self {
        case .largeV3: return "WhisperModel-large-v3_947MB"
        // Argmax's v20240930 is large-v3-turbo. Before VibeScribe offered the original large-v3, these files were
        // called large-v3, so most Macs already have this folder.
        case .largeV3Turbo: return "WhisperModel-large-v3-v20240930_626MB"
        case .barkPlus: return "BarkModel-3.0-plus"
        }
    }

    var developmentFolderName: String {
        switch self {
        case .largeV3: return "WhisperModel-large-v3"
        case .largeV3Turbo: return "WhisperModel-turbo"
        case .barkPlus: return "BarkModel-plus"
        }
    }

    var manifestName: String {
        switch self {
        case .largeV3: return "whisper_model_manifest.json"
        case .largeV3Turbo: return "whisper_model_manifest_turbo.json"
        case .barkPlus: return "bark_model_manifest_plus.json"
        }
    }

    /// Files whose presence means the download finished, checked without hashing them.
    var requiredFiles: [String] {
        switch self {
        case .largeV3, .largeV3Turbo:
            return [
                "AudioEncoder.mlmodelc/weights/weight.bin",
                "MelSpectrogram.mlmodelc/weights/weight.bin",
                "TextDecoder.mlmodelc/weights/weight.bin",
                "tokenizer.json",
                "tokenizer_config.json",
            ]
        case .barkPlus:
            return [
                "BarkEncoder.mlpackage/Manifest.json",
                "BarkEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                "decoder.npz",
                "vocab.json",
            ]
        }
    }

    func makeEngine(modelFolder: URL) -> any SpeechEngine {
        switch self {
        case .largeV3, .largeV3Turbo:
            return WhisperEngine(modelFolder: modelFolder)
        case .barkPlus:
            if #available(macOS 15, *) { return BarkEngine(modelFolder: modelFolder) }
            return UnavailableEngine()
        }
    }
}

/// Stands in for a model this macOS can't run. The app doesn't offer those models.
private actor UnavailableEngine: SpeechEngine {
    func prepare() async throws { throw WhisperModelError.missing }

    func transcribe(segments: [AudioSegment], language: WhisperLanguage, vocabulary: String) async throws -> EngineResult {
        throw WhisperModelError.missing
    }
}

/// The downloadable speech models and which one dictation uses.
@MainActor
final class SpeechModelLibrary: ObservableObject {
    @Published private(set) var activeID: SpeechModelID
    /// Mirrors the active model's state so observers need one subscription.
    @Published private(set) var activeState: WhisperModelSetup.State = .checking
    /// The model loading in the background to replace the active one. Dictation keeps using the active model meanwhile.
    @Published private(set) var pendingID: SpeechModelID?

    let setups: [SpeechModelID: WhisperModelSetup]
    var onActiveChanged: ((SpeechModelID) -> Void)?

    private let preferences: Preferences
    private let logger: Logger
    private let client: WhisperKitClient
    private let makeEngine: (SpeechModelID, URL) -> any SpeechEngine
    private var cancellables = Set<AnyCancellable>()
    private var activeStateSubscription: AnyCancellable?

    var active: WhisperModelSetup { setups[activeID]! }

    init(
        preferences: Preferences,
        logger: Logger,
        client: WhisperKitClient,
        folder: (SpeechModelID) -> URL = { WhisperModelLocator.modelFolder(for: $0) },
        manifest: (SpeechModelID) -> URL = { WhisperModelLocator.manifestURL(for: $0) },
        makeEngine: @escaping (SpeechModelID, URL) -> any SpeechEngine = { $0.makeEngine(modelFolder: $1) }
    ) {
        self.preferences = preferences
        self.logger = logger
        self.client = client
        self.makeEngine = makeEngine
        activeID = SpeechModelID.available.contains(preferences.speechModel) ? preferences.speechModel : .largeV3Turbo
        var setups: [SpeechModelID: WhisperModelSetup] = [:]
        for id in SpeechModelID.available {
            setups[id] = WhisperModelSetup(
                modelID: id,
                manifestURL: manifest(id),
                modelFolder: folder(id),
                logger: logger,
                prepareModel: nil
            )
        }
        self.setups = setups
        for (id, setup) in setups {
            setup.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
            setup.$state
                .sink { [weak self] state in
                    // A cancelled or failed download, or a failed load, ends the switch.
                    switch state {
                    case .notDownloaded, .failed: if self?.pendingID == id { self?.cancelSwitch() }
                    default: break
                    }
                }
                .store(in: &cancellables)
        }
        bindActive()
        for (id, setup) in setups where id != activeID || !WhisperModelLocator.isComplete(setup.modelFolder, for: id) {
            // Missing models show as not downloaded until someone starts the download.
            setup.refreshAvailability()
        }
    }

    func setup(for id: SpeechModelID) -> WhisperModelSetup { setups[id]! }

    /// The language dictation uses: the chosen one, or English while an English-only model is active.
    func language(for chosen: WhisperLanguage) -> WhisperLanguage {
        activeID.isEnglishOnly ? .english : chosen
    }

    /// Core ML reports no progress while it compiles, so this estimates it from when compiling started
    /// and how long the model takes, scaled to this Mac. It fills to 90% at the expected time, then creeps.
    func compileEstimate(for id: SpeechModelID, now: Date = Date()) -> (progress: Double, remaining: TimeInterval)? {
        guard let since = setup(for: id).preparingSince else { return nil }
        let expected = id.compileSeconds * preferences.compileSpeed
        let elapsed = now.timeIntervalSince(since)
        let fraction = elapsed / expected
        let progress = fraction < 1 ? 0.9 * fraction : 0.9 + 0.09 * (1 - exp(-2 * (fraction - 1)))
        return (progress, max(expected - elapsed, 0))
    }

    /// The Whisper model to offer for other languages: one that's already downloaded, else large-v3 turbo.
    var multilingualModel: SpeechModelID {
        let multilingual = SpeechModelID.available.filter { !$0.isEnglishOnly }
        return multilingual.first { setup(for: $0).isReady } ?? .largeV3Turbo
    }

    /// Verifies, and if needed downloads, the model used for dictation.
    func start() {
        active.start()
    }

    /// Picks the model to download during setup. Once a model is on its way, this switches like `switchTo`.
    func choose(_ id: SpeechModelID) {
        guard id != activeID else { return }
        guard !active.isRunning, !active.isReady else {
            switchTo(id)
            return
        }
        active.prepareModel = nil
        activeID = id
        preferences.speechModel = id
        bindActive()
    }

    /// Loads a model in the background and makes it the one dictation uses once it's ready.
    /// Choosing the active model again drops a switch that hasn't finished.
    func switchTo(_ id: SpeechModelID) {
        if let pendingID, pendingID != id {
            setup(for: pendingID).prepareModel = nil
        }
        guard id != activeID else {
            pendingID = nil
            return
        }
        pendingID = id
        let target = setup(for: id)
        target.prepareModel = { [weak self] in try await self?.load(id) }
        if target.isRunning {
            // Still downloading or verifying; it loads the model when that finishes.
            return
        }
        target.start()
    }

    /// Loads the model, then installs it if it's still the one wanted. A load can't be stopped,
    /// so one that was superseded finishes and is thrown away.
    private func load(_ id: SpeechModelID) async throws {
        let engine = makeEngine(id, setup(for: id).modelFolder)
        let started = Date()
        try await engine.prepare()
        let seconds = Date().timeIntervalSince(started)
        // Quick loads came from Core ML's cache and say nothing about how fast this Mac compiles.
        if seconds > 20 {
            preferences.compileSpeed = min(max(seconds / id.compileSeconds, 0.3), 6)
        }
        guard id == activeID || id == pendingID else {
            logger.append("Loaded \(id.shortName), but another model was chosen meanwhile.")
            return
        }
        client.install(engine)
        if id == pendingID { activate(id) }
        logger.append("Speech model \(id.shortName) is ready.", level: .info)
    }

    private func activate(_ id: SpeechModelID) {
        active.prepareModel = nil
        pendingID = nil
        activeID = id
        preferences.speechModel = id
        bindActive()
        onActiveChanged?(id)
    }

    private func cancelSwitch() {
        guard let pendingID else { return }
        setup(for: pendingID).prepareModel = nil
        self.pendingID = nil
    }

    private func bindActive() {
        let id = activeID
        active.prepareModel = { [weak self] in try await self?.load(id) }
        activeStateSubscription = active.$state
            .sink { [weak self] state in self?.activeState = state }
    }
}
