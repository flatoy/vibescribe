import Foundation
@testable import VibeScribeCore

@MainActor
func runAppStateTests(_ t: TestHarness) {
    let apiKeyDefaultsKey = "VibeScribe.ApiKey"
    let languageDefaultsKey = "VibeScribe.DeepgramLanguage"

    func reset() {
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: languageDefaultsKey)
    }

    t.run("handleTranscript builds final transcript") {
        reset()
        let state = AppState()
        state.resetTranscript()

        state.handleTranscript(" hello ", isFinal: true)
        t.expectEqual(state.finalTranscript, "hello")

        state.handleTranscript("hello", isFinal: true)
        t.expectEqual(state.finalTranscript, "hello")

        state.handleTranscript("world", isFinal: true)
        t.expectEqual(state.finalTranscript, "hello world")
    }

    t.run("handleTranscript ignores empty final text") {
        reset()
        let state = AppState()
        state.resetTranscript()
        state.handleTranscript(" ", isFinal: true)
        t.expectEqual(state.finalTranscript, "")
    }

    t.run("non-final transcript updates last only") {
        reset()
        let state = AppState()
        state.resetTranscript()
        state.handleTranscript("partial", isFinal: false)
        t.expectEqual(state.lastTranscript, "partial")
        t.expectEqual(state.finalTranscript, "")
    }

    t.run("resetTranscript clears state") {
        reset()
        let state = AppState()
        state.handleTranscript("hello", isFinal: true)
        state.resetTranscript()
        t.expectEqual(state.lastTranscript, "")
        t.expectEqual(state.finalTranscript, "")
    }

    t.run("deepgramLanguage defaults to automatic") {
        reset()
        let state = AppState()
        t.expectEqual(state.deepgramLanguage, .automatic)
    }

    t.run("deepgramLanguage persists") {
        reset()
        let state = AppState()
        state.deepgramLanguage = .french
        let restored = AppState()
        t.expectEqual(restored.deepgramLanguage, .french)
        reset()
    }
}
