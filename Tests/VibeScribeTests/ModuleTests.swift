import Foundation
@testable import VibeScribeCore

@MainActor
func runTranscriptBufferTests(_ t: TestHarness) {
    t.run("buildsFinalTranscript across multiple final segments") {
        let buffer = TranscriptBuffer()
        buffer.handle(" hello ", isFinal: true)
        t.expectEqual(buffer.final, "hello")

        buffer.handle("hello", isFinal: true)
        t.expectEqual(buffer.final, "hello")

        buffer.handle("world", isFinal: true)
        t.expectEqual(buffer.final, "hello world")
    }

    t.run("ignores empty final text") {
        let buffer = TranscriptBuffer()
        buffer.handle(" ", isFinal: true)
        t.expectEqual(buffer.final, "")
    }

    t.run("non-final transcript updates last only") {
        let buffer = TranscriptBuffer()
        buffer.handle("partial", isFinal: false)
        t.expectEqual(buffer.last, "partial")
        t.expectEqual(buffer.final, "")
    }

    t.run("reset clears state") {
        let buffer = TranscriptBuffer()
        buffer.handle("hello", isFinal: true)
        buffer.reset()
        t.expectEqual(buffer.last, "")
        t.expectEqual(buffer.final, "")
    }

    t.run("effectiveText prefers final, falls back to last") {
        let buffer = TranscriptBuffer()
        buffer.handle("partial", isFinal: false)
        t.expectEqual(buffer.effectiveText, "partial")
        buffer.handle("done", isFinal: true)
        t.expectEqual(buffer.effectiveText, "done")
    }
}

@MainActor
func runPreferencesTests(_ t: TestHarness) {
    func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "VibeScribeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    t.run("language defaults to automatic") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            t.expectEqual(prefs.language, .automatic)
        }
    }

    t.run("language persists across instances") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.language = WhisperLanguage(rawValue: "fr")!
            let restored = Preferences(defaults: defaults)
            t.expectEqual(restored.language, WhisperLanguage(rawValue: "fr")!)
        }
    }

    t.run("migrates regional Deepgram choice and deletes old credentials") {
        withDefaults { defaults in
            defaults.set("en-GB", forKey: "VibeScribe.DeepgramLanguage")
            defaults.set("old-secret", forKey: "VibeScribe.ApiKey")
            let prefs = Preferences(defaults: defaults)
            t.expectEqual(prefs.language, .english)
            t.expectEqual(defaults.string(forKey: "VibeScribe.WhisperLanguage"), "en")
            t.expectNil(defaults.string(forKey: "VibeScribe.DeepgramLanguage"))
            t.expectNil(defaults.string(forKey: "VibeScribe.ApiKey"))
        }
    }

    t.run("unsupported saved language falls back to automatic") {
        withDefaults { defaults in
            defaults.set("en-US", forKey: "VibeScribe.WhisperLanguage")
            let prefs = Preferences(defaults: defaults)
            t.expectEqual(prefs.language, .automatic)
        }
    }
}

@MainActor
func runWhisperLanguageTests(_ t: TestHarness) {
    t.run("picker contains automatic and the 100 Whisper languages") {
        t.expectEqual(WhisperLanguage.allCases.count, 101)
        t.expectEqual(WhisperLanguage.allCases.first, .automatic)
        t.expect(WhisperLanguage(rawValue: "yue") != nil)
        t.expectNil(WhisperLanguage(rawValue: "en-US"))
        t.expect(WhisperLanguage.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    t.run("automatic uses detection and selected language uses its token code") {
        t.expectNil(WhisperLanguage.automatic.whisperCode)
        t.expectEqual(WhisperLanguage.english.whisperCode, "en")
    }
}

@MainActor
func runLoggerTests(_ t: TestHarness) {
    t.run("append adds entries in order") {
        let logger = Logger()
        logger.append("first")
        logger.append("second", level: .warning)
        t.expectEqual(logger.entries.count, 2)
        t.expectEqual(logger.entries[0].message, "first")
        t.expectEqual(logger.entries[0].level, .info)
        t.expectEqual(logger.entries[1].message, "second")
        t.expectEqual(logger.entries[1].level, .warning)
    }

    t.run("clear empties entries") {
        let logger = Logger()
        logger.append("one")
        logger.clear()
        t.expectEqual(logger.entries.count, 0)
    }
}
