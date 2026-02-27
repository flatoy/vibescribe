import XCTest
@testable import VibeScribeCore

@MainActor
final class LiveTextInjectionControllerTests: XCTestCase {
    func testAppendOnlySuffixWhenTargetExtendsPreviousText() {
        let suffix = LiveTextInjectionController.appendOnlySuffix(from: "hello", to: "hello world")
        XCTAssertEqual(suffix, " world")
    }

    func testAppendOnlySuffixWhenTargetDoesNotExtendPreviousText() {
        let suffix = LiveTextInjectionController.appendOnlySuffix(from: "hello world", to: "hello there")
        XCTAssertNil(suffix)
    }

    func testAppendDecisionReturnsAppendWithSuffix() {
        let decision = LiveTextInjectionController.appendDecision(from: "hello", to: "hello world")
        XCTAssertEqual(decision, .append(" world"))
    }

    func testAppendDecisionReturnsRebaseForNonAppendCorrection() {
        let decision = LiveTextInjectionController.appendDecision(from: "i cant", to: "I can't")
        XCTAssertEqual(decision, .rebase)
    }

    func testSalvageAppendSuffixRecoversTrailingWordsAfterCorrection() {
        let suffix = LiveTextInjectionController.salvageAppendSuffix(
            from: "i cant",
            to: "I can't continue"
        )
        XCTAssertEqual(suffix, " continue")
    }

    func testSalvageAppendSuffixReturnsNilWhenNoSequenceMatch() {
        let suffix = LiveTextInjectionController.salvageAppendSuffix(
            from: "hello world",
            to: "completely different"
        )
        XCTAssertNil(suffix)
    }

    func testFallbackTextReturnsOnlyMissingSuffixWhenAlreadyInjected() {
        let text = LiveTextInjectionController.fallbackText(
            finalText: "hello world",
            injectedText: "hello"
        )
        XCTAssertEqual(text, " world")
    }

    func testFallbackTextReturnsEmptyWhenInjectedTextDoesNotMatchPrefix() {
        let text = LiveTextInjectionController.fallbackText(
            finalText: "hello world",
            injectedText: "goodbye"
        )
        XCTAssertEqual(text, "")
    }

    func testFallbackTextReturnsEmptyForWhitespaceFinalText() {
        let text = LiveTextInjectionController.fallbackText(
            finalText: "  \n ",
            injectedText: "hello"
        )
        XCTAssertEqual(text, "")
    }

    func testFallbackTextReturnsFullFinalWhenNothingWasInjected() {
        let text = LiveTextInjectionController.fallbackText(
            finalText: "hello world",
            injectedText: ""
        )
        XCTAssertEqual(text, "hello world")
    }
}
