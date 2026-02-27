import XCTest
@testable import VibeScribeCore

@MainActor
final class LiveTextInjectionControllerTests: XCTestCase {
    func testRewriteOperationForAppendOnly() {
        let operation = LiveTextInjectionController.rewriteOperation(from: "hello", to: "hello world")
        XCTAssertEqual(operation, .init(deleteCount: 0, insertSuffix: " world"))
    }

    func testRewriteOperationForMidWordCorrection() {
        let operation = LiveTextInjectionController.rewriteOperation(from: "helo", to: "hello")
        XCTAssertEqual(operation, .init(deleteCount: 1, insertSuffix: "lo"))
    }

    func testRewriteOperationForReplacementAfterPrefix() {
        let operation = LiveTextInjectionController.rewriteOperation(from: "hello world", to: "hello there")
        XCTAssertEqual(operation, .init(deleteCount: 5, insertSuffix: "there"))
    }

    func testFallbackTextReturnsOnlyMissingSuffixWhenAlreadyInjected() {
        let text = LiveTextInjectionController.fallbackText(
            finalText: "hello world",
            injectedText: "hello"
        )
        XCTAssertEqual(text, " world")
    }

    func testFallbackTextReturnsFullFinalWhenInjectedTextDoesNotMatchPrefix() {
        let text = LiveTextInjectionController.fallbackText(
            finalText: "hello world",
            injectedText: "goodbye"
        )
        XCTAssertEqual(text, "hello world")
    }

    func testFallbackTextReturnsEmptyForWhitespaceFinalText() {
        let text = LiveTextInjectionController.fallbackText(
            finalText: "  \n ",
            injectedText: "hello"
        )
        XCTAssertEqual(text, "")
    }
}
