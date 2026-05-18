import Foundation

@MainActor
func main() async {
    let harness = TestHarness()

    print("String+Trim")
    runStringTrimTests(harness)

    print("AudioBufferConverter")
    runAudioBufferConverterTests(harness)

    print("AppState")
    runAppStateTests(harness)

    let ok = harness.summarize()
    exit(ok ? 0 : 1)
}

await main()
