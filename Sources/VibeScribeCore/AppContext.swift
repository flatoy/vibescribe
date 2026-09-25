import AppKit
import Foundation

/// The shared objects the windows need, plus the actions they can trigger.
@MainActor
final class AppContext {
    let preferences: Preferences
    let permissions: Permissions
    let models: SpeechModelLibrary
    let history: TranscriptHistory
    let logger: Logger
    let status: AppStatus
    let microphones: MicrophoneMonitor
    let loginItem: LoginItem
    let recorder: HotkeyRecorder
    let output: TextOutput

    var openLanguagePicker: (LanguagePickerModel.Mode) -> Void = { _ in }
    var openSettings: (SettingsPage) -> Void = { _ in }
    var openSetup: () -> Void = {}
    var pasteAgain: (HistoryEntry) -> Void = { _ in }

    init(
        preferences: Preferences,
        permissions: Permissions,
        models: SpeechModelLibrary,
        history: TranscriptHistory,
        logger: Logger,
        status: AppStatus,
        microphones: MicrophoneMonitor,
        loginItem: LoginItem,
        recorder: HotkeyRecorder,
        output: TextOutput
    ) {
        self.preferences = preferences
        self.permissions = permissions
        self.models = models
        self.history = history
        self.logger = logger
        self.status = status
        self.microphones = microphones
        self.loginItem = loginItem
        self.recorder = recorder
        self.output = output
    }

    /// Version, permissions, model and recent log lines, for bug reports.
    func diagnosticReport() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let formatter = ISO8601DateFormatter()
        var lines = [
            "VibeScribe \(AppInfo.version)\(AppInfo.build.map { " (\($0))" } ?? "")",
            "macOS \(os)",
            "Speech model: \(models.activeID.shortName) — \(String(describing: models.activeState))",
            "Microphone: \(permissions.microphone.rawValue)",
            "Input Monitoring: \(permissions.inputMonitoring.rawValue)",
            "Accessibility: \(permissions.accessibility.rawValue)",
            "Shortcut: \(preferences.pushToTalkHotkey.displayName) · \(preferences.triggerMode.title)",
            "Language: \(preferences.language.displayName)",
            "Send text to: \(preferences.outputMode.title)",
            "",
            "Log:",
        ]
        lines += logger.entries.suffix(200).map {
            "\(formatter.string(from: $0.timestamp)) \($0.level.rawValue) \($0.message)"
        }
        return lines.joined(separator: "\n")
    }
}
