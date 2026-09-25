import Foundation
@testable import VibeScribeCore

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

    print("WhisperLanguage")
    runWhisperLanguageTests(harness)

    print("LanguagePickerLayout")
    runLanguagePickerLayoutTests(harness)

    print("Logger")
    runLoggerTests(harness)

    print("HotkeyCoordinator")
    runHotkeyCoordinatorTests(harness)

    print("RecordingSession")
    runRecordingSessionTests(harness)

    print("ModelDownload")
    await runModelDownloadTests(harness)

    if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--download-smoke" {
        print("Remote model download")
        await runRemoteModelDownloadSmoke(harness)
    }

    if [4, 5, 6].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--model-smoke" {
        let language = CommandLine.arguments.count >= 5
            ? WhisperLanguage(rawValue: CommandLine.arguments[4]) : .english
        guard let language else {
            fputs("Unsupported language code.\n", stderr)
            exit(1)
        }
        print("Offline model")
        await runOfflineModelSmoke(
            harness,
            modelFolder: CommandLine.arguments[2],
            audioPath: CommandLine.arguments[3],
            language: language,
            requiredTerms: CommandLine.arguments.count == 6
                ? CommandLine.arguments[5].split(separator: ",").map(String.init) : []
        )
    }

    let ok = harness.summarize()
    exit(ok ? 0 : 1)
}

await main()
