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
    let apiKeyDefaultsKey = "VibeScribe.ApiKey"
    let languageDefaultsKey = "VibeScribe.DeepgramLanguage"

    func reset() {
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: languageDefaultsKey)
    }

    t.run("deepgramLanguage defaults to automatic") {
        reset()
        let prefs = Preferences()
        t.expectEqual(prefs.deepgramLanguage, .automatic)
    }

    t.run("deepgramLanguage persists across instances") {
        reset()
        let prefs = Preferences()
        prefs.deepgramLanguage = .french
        let restored = Preferences()
        t.expectEqual(restored.deepgramLanguage, .french)
        reset()
    }

    t.run("apiKey persists across instances") {
        reset()
        let prefs = Preferences()
        prefs.apiKey = "test-key-123"
        let restored = Preferences()
        t.expectEqual(restored.apiKey, "test-key-123")
        reset()
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
