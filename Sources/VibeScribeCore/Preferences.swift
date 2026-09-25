import Foundation

@MainActor
final class Preferences: ObservableObject {
    private static let languageKey = "VibeScribe.WhisperLanguage"
    private static let oldLanguageKey = "VibeScribe.DeepgramLanguage"
    private static let oldApiKey = "VibeScribe.ApiKey"

    private let defaults: UserDefaults

    @Published var language: WhisperLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.languageKey),
           let language = WhisperLanguage(rawValue: saved) {
            self.language = language
        } else {
            self.language = Self.migrateLanguage(defaults.string(forKey: Self.oldLanguageKey))
            defaults.set(language.rawValue, forKey: Self.languageKey)
        }
        defaults.removeObject(forKey: Self.oldLanguageKey)
        defaults.removeObject(forKey: Self.oldApiKey)
    }

    private static func migrateLanguage(_ saved: String?) -> WhisperLanguage {
        guard let saved, saved != "automatic" else { return .automatic }
        let code = String(saved.split(separator: "-").first ?? Substring(saved))
        return WhisperLanguage(rawValue: code) ?? .automatic
    }
}
