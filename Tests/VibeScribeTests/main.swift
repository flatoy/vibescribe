import Foundation

@MainActor
func main() async {
    let harness = TestHarness()

    print("String+Trim")
    runStringTrimTests(harness)

    print("AudioBufferConverter")
    runAudioBufferConverterTests(harness)

    print("TranscriptBuffer")
    runTranscriptBufferTests(harness)

    print("Preferences")
    runPreferencesTests(harness)

    print("Logger")
    runLoggerTests(harness)

    print("HotkeyCoordinator")
    runHotkeyCoordinatorTests(harness)

    let ok = harness.summarize()
    exit(ok ? 0 : 1)
}

await main()
