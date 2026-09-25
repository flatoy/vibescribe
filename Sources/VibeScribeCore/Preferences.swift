import Foundation

enum TriggerMode: String, CaseIterable, Sendable {
    case holdOrTap
    case holdOnly
    case tapOnly

    var title: String {
        switch self {
        case .holdOrTap: return "Hold or tap"
        case .holdOnly: return "Hold only"
        case .tapOnly: return "Tap only"
        }
    }
}

enum OutputMode: String, CaseIterable, Sendable {
    case paste
    case clipboard

    var title: String {
        switch self {
        case .paste: return "Active app"
        case .clipboard: return "Clipboard only"
        }
    }
}

enum HistoryRetention: String, CaseIterable, Sendable {
    case off
    case day
    case week
    case month
    case forever

    var title: String {
        switch self {
        case .off: return "Don’t keep history"
        case .day: return "Keep 1 day"
        case .week: return "Keep 7 days"
        case .month: return "Keep 30 days"
        case .forever: return "Keep forever"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: return 0
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .forever: return nil
        }
    }
}

@MainActor
final class Preferences: ObservableObject {
    static let maxPinnedLanguages = 3
    static let maxRecentLanguages = 3

    private enum Key {
        static let language = "VibeScribe.WhisperLanguage"
        static let oldLanguage = "VibeScribe.DeepgramLanguage"
        static let oldApiKey = "VibeScribe.ApiKey"
        static let pinned = "VibeScribe.PinnedLanguages"
        static let recent = "VibeScribe.RecentLanguages"
        static let pushToTalk = "VibeScribe.PushToTalkHotkey"
        static let languagePicker = "VibeScribe.LanguagePickerHotkey"
        static let triggerMode = "VibeScribe.TriggerMode"
        static let microphone = "VibeScribe.MicrophoneUID"
        static let playSounds = "VibeScribe.PlaySounds"
        static let outputMode = "VibeScribe.OutputMode"
        static let restoreClipboard = "VibeScribe.RestoreClipboard"
        static let showLanguage = "VibeScribe.ShowLanguageInMenuBar"
        static let vocabulary = "VibeScribe.Vocabulary"
        static let retention = "VibeScribe.HistoryRetention"
        static let onboarding = "VibeScribe.CompletedOnboarding"
        static let speechModel = "VibeScribe.SpeechModel"
    }

    private let defaults: UserDefaults

    @Published var language: WhisperLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }
    @Published var pinnedLanguages: [WhisperLanguage] {
        didSet { defaults.set(pinnedLanguages.map(\.rawValue), forKey: Key.pinned) }
    }
    @Published private(set) var recentLanguages: [WhisperLanguage] {
        didSet { defaults.set(recentLanguages.map(\.rawValue), forKey: Key.recent) }
    }
    @Published var pushToTalkHotkey: Hotkey {
        didSet { Self.save(pushToTalkHotkey, key: Key.pushToTalk, in: defaults) }
    }
    @Published var languagePickerHotkey: Hotkey {
        didSet { Self.save(languagePickerHotkey, key: Key.languagePicker, in: defaults) }
    }
    @Published var triggerMode: TriggerMode {
        didSet { defaults.set(triggerMode.rawValue, forKey: Key.triggerMode) }
    }
    /// `nil` follows the system default input device.
    @Published var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: Key.microphone) }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Key.playSounds) }
    }
    @Published var outputMode: OutputMode {
        didSet { defaults.set(outputMode.rawValue, forKey: Key.outputMode) }
    }
    @Published var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) }
    }
    @Published var showLanguageInMenuBar: Bool {
        didSet { defaults.set(showLanguageInMenuBar, forKey: Key.showLanguage) }
    }
    @Published var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary) }
    }
    @Published var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Key.retention) }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarding) }
    }
    @Published var speechModel: SpeechModelID {
        didSet { defaults.set(speechModel.rawValue, forKey: Key.speechModel) }
    }
    /// Not persisted: pausing the shortcut lasts until relaunch.
    @Published var isShortcutPaused = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let saved = defaults.string(forKey: Key.language),
           let language = WhisperLanguage(rawValue: saved) {
            self.language = language
        } else {
            let migrated = Self.migrateLanguage(defaults.string(forKey: Key.oldLanguage))
            self.language = migrated
            defaults.set(migrated.rawValue, forKey: Key.language)
        }
        defaults.removeObject(forKey: Key.oldLanguage)
        defaults.removeObject(forKey: Key.oldApiKey)

        pinnedLanguages = Self.languages(defaults.stringArray(forKey: Key.pinned)) ?? [.automatic, .english]
        recentLanguages = Self.languages(defaults.stringArray(forKey: Key.recent)) ?? []
        pushToTalkHotkey = Self.load(key: Key.pushToTalk, from: defaults) ?? .pushToTalkDefault
        languagePickerHotkey = Self.load(key: Key.languagePicker, from: defaults) ?? .languagePickerDefault
        triggerMode = defaults.string(forKey: Key.triggerMode).flatMap(TriggerMode.init(rawValue:)) ?? .holdOrTap
        microphoneUID = defaults.string(forKey: Key.microphone)
        playSounds = defaults.object(forKey: Key.playSounds) as? Bool ?? true
        outputMode = defaults.string(forKey: Key.outputMode).flatMap(OutputMode.init(rawValue:)) ?? .paste
        restoreClipboard = defaults.object(forKey: Key.restoreClipboard) as? Bool ?? true
        showLanguageInMenuBar = defaults.object(forKey: Key.showLanguage) as? Bool ?? true
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? ""
        historyRetention = defaults.string(forKey: Key.retention).flatMap(HistoryRetention.init(rawValue:)) ?? .month
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarding)
        speechModel = defaults.string(forKey: Key.speechModel).flatMap(SpeechModelID.init(rawValue:)) ?? .largeV3
    }

    /// Chooses a language and remembers it as recent.
    func select(_ language: WhisperLanguage) {
        self.language = language
        var recents = recentLanguages.filter { $0 != language }
        recents.insert(language, at: 0)
        recentLanguages = Array(recents.prefix(Self.maxRecentLanguages))
    }

    /// Pins or unpins a language. Returns `false` when all pin slots are taken.
    @discardableResult
    func togglePin(_ language: WhisperLanguage) -> Bool {
        if let index = pinnedLanguages.firstIndex(of: language) {
            pinnedLanguages.remove(at: index)
            return true
        }
        guard pinnedLanguages.count < Self.maxPinnedLanguages else { return false }
        pinnedLanguages.append(language)
        return true
    }

    var vocabularyWords: [String] {
        vocabulary
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    private static func languages(_ codes: [String]?) -> [WhisperLanguage]? {
        codes.map { $0.compactMap(WhisperLanguage.init(rawValue:)) }
    }

    private static func save(_ hotkey: Hotkey, key: String, in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(hotkey), forKey: key)
    }

    private static func load(key: String, from defaults: UserDefaults) -> Hotkey? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
    }

    private static func migrateLanguage(_ saved: String?) -> WhisperLanguage {
        guard let saved, saved != "automatic" else { return .automatic }
        let code = String(saved.split(separator: "-").first ?? Substring(saved))
        return WhisperLanguage(rawValue: code) ?? .automatic
    }
}
