import Foundation
@testable import VibeScribeCore

@MainActor
func runDeepgramParserTests(_ t: TestHarness) {
    t.run("parses interim transcript with is_final=false") {
        let json = """
        {"channel":{"alternatives":[{"transcript":"hello world"}]},"is_final":false}
        """
        let result = DeepgramClient.parseMessage(json)
        t.expectEqual(result, .transcript(text: "hello world", isFinal: false))
    }

    t.run("parses final transcript with is_final=true") {
        let json = """
        {"channel":{"alternatives":[{"transcript":"done"}]},"is_final":true}
        """
        let result = DeepgramClient.parseMessage(json)
        t.expectEqual(result, .transcript(text: "done", isFinal: true))
    }

    t.run("speech_final and from_finalize also mark transcript final") {
        let speechFinal = """
        {"channel":{"alternatives":[{"transcript":"a"}]},"speech_final":true}
        """
        t.expectEqual(DeepgramClient.parseMessage(speechFinal), .transcript(text: "a", isFinal: true))

        let fromFinalize = """
        {"channel":{"alternatives":[{"transcript":"b"}]},"from_finalize":true}
        """
        t.expectEqual(DeepgramClient.parseMessage(fromFinalize), .transcript(text: "b", isFinal: true))
    }

    t.run("returns nil for empty transcript") {
        let json = """
        {"channel":{"alternatives":[{"transcript":""}]},"is_final":true}
        """
        t.expectNil(DeepgramClient.parseMessage(json))
    }

    t.run("returns nil for missing channel") {
        let json = """
        {"type":"Metadata"}
        """
        t.expectNil(DeepgramClient.parseMessage(json))
    }

    t.run("parses error message") {
        let json = """
        {"type":"Error","description":"invalid model"}
        """
        t.expectEqual(DeepgramClient.parseMessage(json), .errorMessage("invalid model"))
    }

    t.run("returns nil for malformed JSON") {
        t.expectNil(DeepgramClient.parseMessage("not json"))
    }
}
