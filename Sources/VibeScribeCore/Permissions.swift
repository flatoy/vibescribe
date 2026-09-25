import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

enum PermissionStatus: String {
    case notDetermined = "Not requested"
    case denied = "Not granted"
    case authorized = "Granted"

    var isGranted: Bool { self == .authorized }
}

@MainActor
final class Permissions: ObservableObject {
    @Published private(set) var microphone: PermissionStatus = .notDetermined
    @Published private(set) var inputMonitoring: PermissionStatus = .notDetermined
    @Published private(set) var accessibility: PermissionStatus = .notDetermined

    private var pollTimer: Timer?
    private var pollClients = 0
    private var askedInputMonitoring = false
    private var askedAccessibility = false

    init() {
        refresh()
    }

    func refresh() {
        let mic: PermissionStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .authorized
        case .denied, .restricted: mic = .denied
        case .notDetermined: mic = .notDetermined
        @unknown default: mic = .denied
        }
        if mic != microphone { microphone = mic }
        let input: PermissionStatus = CGPreflightListenEventAccess() ? .authorized : .denied
        if input != inputMonitoring { inputMonitoring = input }
        let ax: PermissionStatus = AXIsProcessTrusted() ? .authorized : .denied
        if ax != accessibility { accessibility = ax }
    }

    /// Polls while a window that shows permissions is open, so rows update after System Settings.
    func beginPolling() {
        pollClients += 1
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func endPolling() {
        pollClients = max(0, pollClients - 1)
        guard pollClients == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func requestMicrophone() {
        guard microphone == .notDetermined else {
            SystemSettings.open(.microphone)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Shows the system prompt the first time; afterwards only System Settings can change it.
    func requestInputMonitoring() {
        if askedInputMonitoring {
            SystemSettings.open(.inputMonitoring)
        } else {
            askedInputMonitoring = true
            // The system prompt offers to open System Settings; the helper follows it there.
            SystemSettings.didOpen?(.inputMonitoring)
            _ = CGRequestListenEventAccess()
        }
        refresh()
    }

    func requestAccessibility() {
        if askedAccessibility {
            SystemSettings.open(.accessibility)
        } else {
            askedAccessibility = true
            SystemSettings.didOpen?(.accessibility)
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        refresh()
    }

    /// For previews and README screenshots.
    func simulate(microphone: PermissionStatus, inputMonitoring: PermissionStatus, accessibility: PermissionStatus) {
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.accessibility = accessibility
    }
}
