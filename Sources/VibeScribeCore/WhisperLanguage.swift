import Foundation
import WhisperKit

struct WhisperLanguage: Hashable, Identifiable, Sendable {
    let rawValue: String

    var id: String { rawValue }
    var whisperCode: String? { self == .automatic ? nil : rawValue }
    var menuBarLabel: String { self == .automatic ? "🌐" : rawValue.uppercased() }

    static let automatic = WhisperLanguage(rawValue: "automatic")!
    static let english = WhisperLanguage(rawValue: "en")!

    // The downloaded large-v3 tokenizer has every WhisperKit language token.
    private static let supportedCodes = Constants.languageCodes

    static let allCases: [WhisperLanguage] = [.automatic] + supportedCodes
        .compactMap(WhisperLanguage.init(rawValue:))
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

    init?(rawValue: String) {
        guard rawValue == "automatic" || Self.supportedCodes.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    var displayName: String {
        guard self != .automatic else { return "Automatic" }
        if let name = Self.englishLocale.localizedString(forLanguageCode: rawValue), name != rawValue {
            return name.capitalized
        }
        let name = Constants.languages
            .filter { $0.value == rawValue }
            .map(\.key)
            .sorted()
            .first ?? rawValue
        return name.capitalized
    }

    private static let englishLocale = Locale(identifier: "en")
}
