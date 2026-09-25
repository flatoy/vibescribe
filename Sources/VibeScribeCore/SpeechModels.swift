import Combine
import Foundation

enum SpeechModelID: String, CaseIterable, Identifiable, Sendable {
    case largeV3
    case largeV3Turbo

    var id: String { rawValue }

    var name: String {
        switch self {
        case .largeV3: return "Whisper large-v3"
        case .largeV3Turbo: return "Whisper large-v3 turbo"
        }
    }

    var shortName: String {
        switch self {
        case .largeV3: return "large-v3"
        case .largeV3Turbo: return "large-v3 turbo"
        }
    }

    var summary: String {
        switch self {
        case .largeV3: return "Most accurate · 100 languages"
        case .largeV3Turbo: return "Roughly 3× faster to transcribe. Slightly less accurate in less common languages"
        }
    }

    var badge: String {
        switch self {
        case .largeV3: return "Most accurate"
        case .largeV3Turbo: return "Faster"
        }
    }

    var folderName: String {
        switch self {
        case .largeV3: return "WhisperModel-large-v3-v20240930_626MB"
        case .largeV3Turbo: return "WhisperModel-large-v3-v20240930_turbo_632MB"
        }
    }

    var developmentFolderName: String {
        switch self {
        case .largeV3: return "WhisperModel"
        case .largeV3Turbo: return "WhisperModel-turbo"
        }
    }

    var manifestName: String {
        switch self {
        case .largeV3: return "whisper_model_manifest.json"
        case .largeV3Turbo: return "whisper_model_manifest_turbo.json"
        }
    }
}

/// The downloadable speech models and which one dictation uses.
@MainActor
final class SpeechModelLibrary: ObservableObject {
    @Published private(set) var activeID: SpeechModelID
    /// Mirrors the active model's state so observers need one subscription.
    @Published private(set) var activeState: WhisperModelSetup.State = .checking

    let setups: [SpeechModelID: WhisperModelSetup]
    var onActiveChanged: ((SpeechModelID) -> Void)?

    private let preferences: Preferences
    private let client: WhisperKitClient
    private var cancellables = Set<AnyCancellable>()
    private var activeStateSubscription: AnyCancellable?

    var active: WhisperModelSetup { setups[activeID]! }

    init(
        preferences: Preferences,
        logger: Logger,
        client: WhisperKitClient,
        folder: (SpeechModelID) -> URL = { WhisperModelLocator.modelFolder(for: $0) },
        manifest: (SpeechModelID) -> URL = { WhisperModelLocator.manifestURL(for: $0) }
    ) {
        self.preferences = preferences
        self.client = client
        activeID = preferences.speechModel
        var setups: [SpeechModelID: WhisperModelSetup] = [:]
        for id in SpeechModelID.allCases {
            setups[id] = WhisperModelSetup(
                modelID: id,
                manifestURL: manifest(id),
                modelFolder: folder(id),
                logger: logger,
                prepareModel: nil
            )
        }
        self.setups = setups
        for setup in setups.values {
            setup.objectWillChange
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        bindActive()
        for (id, setup) in setups where id != activeID || !WhisperModelLocator.isComplete(setup.modelFolder) {
            // Missing models show as not downloaded until someone starts the download.
            setup.refreshAvailability()
        }
    }

    func setup(for id: SpeechModelID) -> WhisperModelSetup { setups[id]! }

    /// Verifies, and if needed downloads, the model used for dictation.
    func start() {
        active.start()
    }

    /// Makes a downloaded model the one used for dictation.
    func switchTo(_ id: SpeechModelID) {
        guard id != activeID else { return }
        active.prepareModel = nil
        active.refreshAvailability()
        activeID = id
        preferences.speechModel = id
        client.use(modelFolder: setup(for: id).modelFolder)
        bindActive()
        active.start()
        onActiveChanged?(id)
    }

    private func bindActive() {
        let client = self.client
        active.prepareModel = { try await client.prepare() }
        activeStateSubscription = active.$state
            .sink { [weak self] state in self?.activeState = state }
    }
}
