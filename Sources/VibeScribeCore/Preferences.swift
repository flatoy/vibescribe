import Foundation

@MainActor
final class Preferences: ObservableObject {
    private static let apiKeyKey = "VibeScribe.ApiKey"
    private static let languageKey = "VibeScribe.DeepgramLanguage"

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey)
        }
    }

    @Published var deepgramLanguage: DeepgramLanguage {
        didSet {
            UserDefaults.standard.set(deepgramLanguage.rawValue, forKey: Self.languageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.apiKey = defaults.string(forKey: Self.apiKeyKey) ?? ""
        let saved = defaults.string(forKey: Self.languageKey)
        self.deepgramLanguage = saved.flatMap(DeepgramLanguage.init(rawValue:)) ?? .automatic
    }
}
