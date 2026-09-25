import Combine
import Foundation

enum AppIssue: Equatable, Sendable {
    case microphoneOff
    case shortcutBlocked
    case pastingOff
    case modelFailed(String)

    var title: String {
        switch self {
        case .microphoneOff: return "Microphone access is off"
        case .shortcutBlocked: return "The shortcut can’t be heard"
        case .pastingOff: return "Pasting is off"
        case .modelFailed: return "Speech model setup stopped"
        }
    }

    var detail: String {
        switch self {
        case .microphoneOff:
            return "VibeScribe can’t hear you until the microphone is allowed."
        case .shortcutBlocked:
            return "Allow Input Monitoring so the shortcut works in other apps."
        case .pastingOff:
            return "Accessibility permission is off, often after an app update. Transcripts are copied instead."
        case .modelFailed(let message):
            return message
        }
    }

    var fixTitle: String {
        switch self {
        case .modelFailed: return "Try again"
        default: return "Turn on in System Settings…"
        }
    }

    var settingsPane: SystemSettings.Pane? {
        switch self {
        case .microphoneOff: return .microphone
        case .shortcutBlocked: return .inputMonitoring
        case .pastingOff: return .accessibility
        case .modelFailed: return nil
        }
    }
}

enum AppPhase: Equatable, Sendable {
    case settingUp(progress: Double?)
    case ready
    case recording
    case transcribing
    case shortcutPaused
    case attention(AppIssue)

    var title: String {
        switch self {
        case .settingUp: return "Setting up"
        case .ready: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .shortcutPaused: return "Shortcut paused"
        case .attention(let issue): return issue.title
        }
    }
}

/// One summary of what the app is doing, for the menu bar, menu and settings sidebar.
@MainActor
final class AppStatus: ObservableObject {
    @Published private(set) var phase: AppPhase = .settingUp(progress: nil)
    /// Problems that need a fix, most important first. May be non-empty while recording.
    @Published private(set) var issues: [AppIssue] = []

    private var cancellables = Set<AnyCancellable>()

    init(
        session: RecordingSession,
        models: SpeechModelLibrary,
        permissions: Permissions,
        preferences: Preferences
    ) {
        let inputs = Publishers.CombineLatest4(
            session.$state,
            models.$activeState,
            Publishers.CombineLatest3(permissions.$microphone, permissions.$inputMonitoring, permissions.$accessibility),
            Publishers.CombineLatest(preferences.$outputMode, preferences.$isShortcutPaused)
        )
        inputs
            .sink { [weak self] session, model, access, prefs in
                let issues = Self.issues(
                    model: model,
                    microphone: access.0,
                    inputMonitoring: access.1,
                    accessibility: access.2,
                    outputMode: prefs.0
                )
                self?.issues = issues
                self?.phase = Self.phase(session: session, model: model, issues: issues, shortcutPaused: prefs.1)
            }
            .store(in: &cancellables)
    }

    /// For previews and README screenshots.
    init(simulated phase: AppPhase, issues: [AppIssue] = []) {
        self.phase = phase
        self.issues = issues
    }

    nonisolated static func issues(
        model: WhisperModelSetup.State,
        microphone: PermissionStatus,
        inputMonitoring: PermissionStatus,
        accessibility: PermissionStatus,
        outputMode: OutputMode
    ) -> [AppIssue] {
        var issues: [AppIssue] = []
        if case .failed(let message) = model { issues.append(.modelFailed(message)) }
        if microphone == .denied { issues.append(.microphoneOff) }
        if inputMonitoring == .denied { issues.append(.shortcutBlocked) }
        if accessibility == .denied, outputMode == .paste { issues.append(.pastingOff) }
        return issues
    }

    nonisolated static func phase(
        session: RecordingSession.State,
        model: WhisperModelSetup.State,
        issues: [AppIssue],
        shortcutPaused: Bool
    ) -> AppPhase {
        switch session {
        case .recording: return .recording
        case .finalizing: return .transcribing
        case .idle: break
        }
        switch model {
        case .ready, .failed: break
        case .checking, .preparing: return .settingUp(progress: nil)
        case .downloading(let completed, let total), .paused(let completed, let total),
             .notDownloaded(let completed, let total), .interrupted(let completed, let total, _):
            return .settingUp(progress: total > 0 ? Double(completed) / Double(total) : nil)
        }
        if let issue = issues.first { return .attention(issue) }
        return shortcutPaused ? .shortcutPaused : .ready
    }
}
