import Foundation

enum DeepgramLanguage: String, CaseIterable, Identifiable {
    case automatic
    case arabic = "ar"
    case arabicUnitedArabEmirates = "ar-AE"
    case arabicSaudiArabia = "ar-SA"
    case arabicQatar = "ar-QA"
    case arabicKuwait = "ar-KW"
    case arabicSyria = "ar-SY"
    case arabicLebanon = "ar-LB"
    case arabicPalestine = "ar-PS"
    case arabicJordan = "ar-JO"
    case arabicEgypt = "ar-EG"
    case arabicSudan = "ar-SD"
    case arabicChad = "ar-TD"
    case arabicMorocco = "ar-MA"
    case arabicAlgeria = "ar-DZ"
    case arabicTunisia = "ar-TN"
    case arabicIraq = "ar-IQ"
    case arabicIran = "ar-IR"
    case belarusian = "be"
    case bengali = "bn"
    case bosnian = "bs"
    case bulgarian = "bg"
    case catalan = "ca"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case danishDenmark = "da-DK"
    case dutch = "nl"
    case english = "en"
    case englishAmerican = "en-US"
    case englishAustralian = "en-AU"
    case englishBritish = "en-GB"
    case englishIndian = "en-IN"
    case englishNewZealand = "en-NZ"
    case estonian = "et"
    case finnish = "fi"
    case flemish = "nl-BE"
    case french = "fr"
    case frenchCanadian = "fr-CA"
    case german = "de"
    case germanSwiss = "de-CH"
    case greek = "el"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case kannada = "kn"
    case korean = "ko"
    case koreanSouthKorea = "ko-KR"
    case latvian = "lv"
    case lithuanian = "lt"
    case macedonian = "mk"
    case malay = "ms"
    case marathi = "mr"
    case norwegian = "no"
    case persian = "fa"
    case polish = "pl"
    case portuguese = "pt"
    case portugueseBrazilian = "pt-BR"
    case portuguesePortugal = "pt-PT"
    case romanian = "ro"
    case russian = "ru"
    case serbian = "sr"
    case slovak = "sk"
    case slovenian = "sl"
    case spanish = "es"
    case spanishLatinAmerica = "es-419"
    case swedish = "sv"
    case swedishSweden = "sv-SE"
    case tagalog = "tl"
    case tamil = "ta"
    case telugu = "te"
    case turkish = "tr"
    case ukrainian = "uk"
    case urdu = "ur"
    case vietnamese = "vi"

    var id: String { rawValue }

    var deepgramCode: String {
        switch self {
        case .automatic:
            return "multi"
        default:
            return rawValue
        }
    }

    var flag: String {
        if self == .automatic {
            return "🌐"
        }
        let raw = rawValue
        if let dash = raw.firstIndex(of: "-") {
            let region = String(raw[raw.index(after: dash)...])
            if region == "419" { return "🌎" }
            return Self.flag(for: region)
        }
        return Self.defaultFlag(for: raw)
    }

    private static let pureLanguageCountry: [String: String] = [
        "ar": "SA", "be": "BY", "bn": "BD", "bs": "BA", "bg": "BG",
        "ca": "ES", "hr": "HR", "cs": "CZ", "da": "DK", "nl": "NL",
        "en": "US", "et": "EE", "fi": "FI", "fr": "FR", "de": "DE",
        "el": "GR", "he": "IL", "hi": "IN", "hu": "HU", "id": "ID",
        "it": "IT", "ja": "JP", "kn": "IN", "ko": "KR", "lv": "LV",
        "lt": "LT", "mk": "MK", "ms": "MY", "mr": "IN", "no": "NO",
        "fa": "IR", "pl": "PL", "pt": "PT", "ro": "RO", "ru": "RU",
        "sr": "RS", "sk": "SK", "sl": "SI", "es": "ES", "sv": "SE",
        "tl": "PH", "ta": "IN", "te": "IN", "tr": "TR", "uk": "UA",
        "ur": "PK", "vi": "VN",
    ]

    private static func defaultFlag(for languageCode: String) -> String {
        guard let country = pureLanguageCountry[languageCode] else {
            return "🌐"
        }
        return flag(for: country)
    }

    private static func flag(for countryCode: String) -> String {
        let base: UInt32 = 127397
        var result = ""
        for scalar in countryCode.uppercased().unicodeScalars {
            if let regional = UnicodeScalar(base + scalar.value) {
                result.unicodeScalars.append(regional)
            }
        }
        return result
    }

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .arabic:
            return "Arabic"
        case .arabicUnitedArabEmirates:
            return "Arabic (United Arab Emirates)"
        case .arabicSaudiArabia:
            return "Arabic (Saudi Arabia)"
        case .arabicQatar:
            return "Arabic (Qatar)"
        case .arabicKuwait:
            return "Arabic (Kuwait)"
        case .arabicSyria:
            return "Arabic (Syria)"
        case .arabicLebanon:
            return "Arabic (Lebanon)"
        case .arabicPalestine:
            return "Arabic (Palestine)"
        case .arabicJordan:
            return "Arabic (Jordan)"
        case .arabicEgypt:
            return "Arabic (Egypt)"
        case .arabicSudan:
            return "Arabic (Sudan)"
        case .arabicChad:
            return "Arabic (Chad)"
        case .arabicMorocco:
            return "Arabic (Morocco)"
        case .arabicAlgeria:
            return "Arabic (Algeria)"
        case .arabicTunisia:
            return "Arabic (Tunisia)"
        case .arabicIraq:
            return "Arabic (Iraq)"
        case .arabicIran:
            return "Arabic (Iran)"
        case .belarusian:
            return "Belarusian"
        case .bengali:
            return "Bengali"
        case .bosnian:
            return "Bosnian"
        case .bulgarian:
            return "Bulgarian"
        case .catalan:
            return "Catalan"
        case .croatian:
            return "Croatian"
        case .czech:
            return "Czech"
        case .danish:
            return "Danish"
        case .danishDenmark:
            return "Danish (Denmark)"
        case .dutch:
            return "Dutch"
        case .english:
            return "English"
        case .englishAmerican:
            return "English (US)"
        case .englishAustralian:
            return "English (Australia)"
        case .englishBritish:
            return "English (UK)"
        case .englishIndian:
            return "English (India)"
        case .englishNewZealand:
            return "English (New Zealand)"
        case .estonian:
            return "Estonian"
        case .finnish:
            return "Finnish"
        case .flemish:
            return "Flemish"
        case .french:
            return "French"
        case .frenchCanadian:
            return "French (Canada)"
        case .german:
            return "German"
        case .germanSwiss:
            return "German (Switzerland)"
        case .greek:
            return "Greek"
        case .hebrew:
            return "Hebrew"
        case .hindi:
            return "Hindi"
        case .hungarian:
            return "Hungarian"
        case .indonesian:
            return "Indonesian"
        case .italian:
            return "Italian"
        case .japanese:
            return "Japanese"
        case .kannada:
            return "Kannada"
        case .korean:
            return "Korean"
        case .koreanSouthKorea:
            return "Korean (South Korea)"
        case .latvian:
            return "Latvian"
        case .lithuanian:
            return "Lithuanian"
        case .macedonian:
            return "Macedonian"
        case .malay:
            return "Malay"
        case .marathi:
            return "Marathi"
        case .norwegian:
            return "Norwegian"
        case .persian:
            return "Persian"
        case .polish:
            return "Polish"
        case .portuguese:
            return "Portuguese"
        case .portugueseBrazilian:
            return "Portuguese (Brazil)"
        case .portuguesePortugal:
            return "Portuguese (Portugal)"
        case .romanian:
            return "Romanian"
        case .russian:
            return "Russian"
        case .serbian:
            return "Serbian"
        case .slovak:
            return "Slovak"
        case .slovenian:
            return "Slovenian"
        case .spanish:
            return "Spanish"
        case .spanishLatinAmerica:
            return "Spanish (Latin America)"
        case .swedish:
            return "Swedish"
        case .swedishSweden:
            return "Swedish (Sweden)"
        case .tagalog:
            return "Tagalog"
        case .tamil:
            return "Tamil"
        case .telugu:
            return "Telugu"
        case .turkish:
            return "Turkish"
        case .ukrainian:
            return "Ukrainian"
        case .urdu:
            return "Urdu"
        case .vietnamese:
            return "Vietnamese"
        }
    }
}
