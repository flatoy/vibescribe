import ApplicationServices
import AVFoundation
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    private static let apiKeyKey = "VibeScribe.ApiKey"
    private static let deepgramLanguageKey = "VibeScribe.DeepgramLanguage"
    private static let liveTranscriptionEnabledKey = "VibeScribe.LiveTranscriptionEnabled"

    @Published var isRecording = false
    @Published var statusMessage = "Idle"
    @Published var lastTranscript = ""
    @Published var finalTranscript = ""
    @Published private(set) var displayTranscript = ""
    @Published var logs: [LogEntry] = []
    @Published var overlayPulseID = UUID()
    @Published var microphonePermission: PermissionStatus = .notDetermined
    @Published var accessibilityPermission: PermissionStatus = .notDetermined

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey)
        }
    }

    @Published var hotkey = Hotkey.pushToTalkDefault
    @Published var deepgramLanguage: DeepgramLanguage {
        didSet {
            UserDefaults.standard.set(deepgramLanguage.rawValue, forKey: Self.deepgramLanguageKey)
        }
    }
    @Published var liveTranscriptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(liveTranscriptionEnabled, forKey: Self.liveTranscriptionEnabledKey)
        }
    }

    init() {
        apiKey = UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
        let savedLanguage = UserDefaults.standard.string(forKey: Self.deepgramLanguageKey)
        deepgramLanguage = savedLanguage.flatMap(DeepgramLanguage.init(rawValue:)) ?? .automatic
        if UserDefaults.standard.object(forKey: Self.liveTranscriptionEnabledKey) == nil {
            liveTranscriptionEnabled = true
        } else {
            liveTranscriptionEnabled = UserDefaults.standard.bool(forKey: Self.liveTranscriptionEnabledKey)
        }
        refreshPermissions()
    }

    func resetTranscript() {
        lastTranscript = ""
        finalTranscript = ""
        displayTranscript = ""
        committedSegments.removeAll()
        activeSegment = ""
    }

    func handleTranscriptEvent(_ event: TranscriptEvent) {
        let trimmed = event.text.trimmed
        lastTranscript = trimmed

        guard event.isFinal else {
            activeSegment = trimmed
            rebuildDisplayTranscript()
            return
        }

        guard !trimmed.isEmpty else {
            activeSegment = ""
            lastTranscript = ""
            rebuildDisplayTranscript()
            return
        }
        if committedSegments.last != trimmed {
            committedSegments.append(trimmed)
        }
        finalTranscript = committedSegments.joined(separator: " ")
        activeSegment = ""
        lastTranscript = ""
        rebuildDisplayTranscript()
    }

    func addLog(_ message: String, level: LogLevel = .info) {
        logs.append(LogEntry(timestamp: Date(), level: level, message: message))
    }

    func clearLogs() {
        logs.removeAll()
    }

    private var committedSegments: [String] = []
    private var activeSegment = ""

    private func rebuildDisplayTranscript() {
        if finalTranscript.isEmpty {
            displayTranscript = activeSegment
            return
        }
        if activeSegment.isEmpty {
            displayTranscript = finalTranscript
            return
        }
        displayTranscript = "\(finalTranscript) \(activeSegment)"
    }
}

enum PermissionStatus: String {
    case notDetermined = "Not requested"
    case denied = "Not granted"
    case authorized = "Granted"

    var isGranted: Bool {
        self == .authorized
    }
}

extension AppState {
    func refreshPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermission = .authorized
        case .denied, .restricted:
            microphonePermission = .denied
        case .notDetermined:
            microphonePermission = .notDetermined
        @unknown default:
            microphonePermission = .denied
        }

        accessibilityPermission = AXIsProcessTrusted() ? .authorized : .denied
    }

    func requestMicrophonePermission(completion: (@Sendable () -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                completion?()
            }
        }
    }

    func requestAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        refreshPermissions()
    }

    func requestInitialPermissionsIfNeeded() {
        refreshPermissions()
        if microphonePermission == .notDetermined {
            requestMicrophonePermission { [weak self] in
                Task { @MainActor in
                    self?.requestAccessibilityPermissionIfNeeded()
                }
            }
            return
        }

        requestAccessibilityPermissionIfNeeded()
    }

    private func requestAccessibilityPermissionIfNeeded() {
        refreshPermissions()
        if accessibilityPermission != .authorized {
            requestAccessibilityPermission()
        }
    }
}
