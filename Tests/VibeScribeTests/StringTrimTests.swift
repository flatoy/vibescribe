@testable import VibeScribeCore

@MainActor
func runStringTrimTests(_ t: TestHarness) {
    t.run("trimmed removes whitespace and newlines") {
        t.expectEqual("  hello\n".trimmed, "hello")
    }

    t.run("nilIfEmpty returns nil for whitespace") {
        t.expectNil("   \n\t  ".nilIfEmpty)
    }

    t.run("nilIfEmpty returns trimmed string") {
        t.expectEqual("  hi  ".nilIfEmpty, "hi")
    }
}
