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
    runSettingsPreferencesTests(harness)

    print("Hotkey")
    runHotkeyTests(harness)

    print("WhisperLanguage")
    runWhisperLanguageTests(harness)

    print("LanguagePickerLayout")
    runLanguagePickerLayoutTests(harness)

    print("LanguagePickerModel")
    runLanguagePickerModelTests(harness)

    print("History")
    runHistoryTests(harness)

    print("AppStatus")
    runAppStatusTests(harness)

    print("Format")
    runFormatTests(harness)

    print("SpeechDetector")
    runSpeechDetectorTests(harness)

    print("PermissionHelper")
    runPermissionHelperTests(harness)

    print("Logger")
    runLoggerTests(harness)

    print("HotkeyCoordinator")
    runHotkeyCoordinatorTests(harness)

    print("RecordingSession")
    runRecordingSessionTests(harness)

    print("ModelDownload")
    await runModelDownloadTests(harness)

    print("ModelSwitch")
    await runModelSwitchTests(harness)

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

    if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--switch-smoke" {
        print("Model switch")
        await runModelSwitchSmoke(
            harness,
            current: CommandLine.arguments[2],
            compiling: CommandLine.arguments[3],
            audioPath: CommandLine.arguments[4]
        )
    }

    let ok = harness.summarize()
    exit(ok ? 0 : 1)
}

await main()
