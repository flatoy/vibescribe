import XCTest
@testable import VibeScribeCore

@MainActor
final class AppStateTests: XCTestCase {
    private let apiKeyDefaultsKey = "VibeScribe.ApiKey"
    private let languageDefaultsKey = "VibeScribe.DeepgramLanguage"
    private let liveTranscriptionDefaultsKey = "VibeScribe.LiveTranscriptionEnabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: languageDefaultsKey)
        UserDefaults.standard.removeObject(forKey: liveTranscriptionDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        UserDefaults.standard.removeObject(forKey: languageDefaultsKey)
        UserDefaults.standard.removeObject(forKey: liveTranscriptionDefaultsKey)
        super.tearDown()
    }

    func testHandleTranscriptBuildsFinalTranscript() {
        let state = AppState()
        state.resetTranscript()

        state.handleTranscriptEvent(makeEvent(" hello ", isFinal: true))
        XCTAssertEqual(state.finalTranscript, "hello")
        XCTAssertEqual(state.displayTranscript, "hello")

        state.handleTranscriptEvent(makeEvent("hello", isFinal: true))
        XCTAssertEqual(state.finalTranscript, "hello")
        XCTAssertEqual(state.displayTranscript, "hello")

        state.handleTranscriptEvent(makeEvent("world", isFinal: true))
        XCTAssertEqual(state.finalTranscript, "hello world")
        XCTAssertEqual(state.displayTranscript, "hello world")
    }

    func testHandleTranscriptIgnoresEmptyFinalText() {
        let state = AppState()
        state.resetTranscript()

        state.handleTranscriptEvent(makeEvent(" ", isFinal: true))
        XCTAssertEqual(state.finalTranscript, "")
        XCTAssertEqual(state.displayTranscript, "")
    }

    func testNonFinalTranscriptUpdatesLastOnly() {
        let state = AppState()
        state.resetTranscript()

        state.handleTranscriptEvent(makeEvent("partial", isFinal: false))
        XCTAssertEqual(state.lastTranscript, "partial")
        XCTAssertEqual(state.finalTranscript, "")
        XCTAssertEqual(state.displayTranscript, "partial")
    }

    func testInterimSegmentAppendsToCommittedTranscriptForDisplay() {
        let state = AppState()
        state.resetTranscript()

        state.handleTranscriptEvent(makeEvent("hello", isFinal: true))
        state.handleTranscriptEvent(makeEvent("wor", isFinal: false))

        XCTAssertEqual(state.finalTranscript, "hello")
        XCTAssertEqual(state.displayTranscript, "hello wor")
        XCTAssertEqual(state.lastTranscript, "wor")
    }

    func testInterimUpdatesReplaceActiveSegmentInsteadOfAppending() {
        let state = AppState()
        state.resetTranscript()

        state.handleTranscriptEvent(makeEvent("hel", isFinal: false))
        XCTAssertEqual(state.displayTranscript, "hel")

        state.handleTranscriptEvent(makeEvent("hello", isFinal: false))
        XCTAssertEqual(state.displayTranscript, "hello")
    }

    func testEmptyFinalClearsActiveSegmentAndKeepsCommittedTranscript() {
        let state = AppState()
        state.resetTranscript()

        state.handleTranscriptEvent(makeEvent("hello", isFinal: true))
        state.handleTranscriptEvent(makeEvent("world", isFinal: false))
        state.handleTranscriptEvent(makeEvent(" ", isFinal: true))

        XCTAssertEqual(state.finalTranscript, "hello")
        XCTAssertEqual(state.displayTranscript, "hello")
        XCTAssertEqual(state.lastTranscript, "")
    }

    func testResetTranscriptClearsState() {
        let state = AppState()
        state.handleTranscriptEvent(makeEvent("hello", isFinal: true))

        state.resetTranscript()
        XCTAssertEqual(state.lastTranscript, "")
        XCTAssertEqual(state.finalTranscript, "")
        XCTAssertEqual(state.displayTranscript, "")
    }

    func testDeepgramLanguageDefaultsToAutomatic() {
        let state = AppState()
        XCTAssertEqual(state.deepgramLanguage, .automatic)
    }

    func testDeepgramLanguagePersists() {
        let state = AppState()
        state.deepgramLanguage = .french

        let restored = AppState()
        XCTAssertEqual(restored.deepgramLanguage, .french)
    }

    func testLiveTranscriptionDefaultsToEnabled() {
        let state = AppState()
        XCTAssertTrue(state.liveTranscriptionEnabled)
    }

    func testLiveTranscriptionPreferencePersists() {
        let state = AppState()
        state.liveTranscriptionEnabled = false

        let restored = AppState()
        XCTAssertFalse(restored.liveTranscriptionEnabled)
    }

    private func makeEvent(_ text: String, isFinal: Bool) -> TranscriptEvent {
        TranscriptEvent(
            text: text,
            isFinal: isFinal,
            isSpeechFinal: isFinal,
            receivedAt: Date()
        )
    }
}
