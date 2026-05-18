import ApplicationServices
import AVFoundation
import Foundation

enum PermissionStatus: String {
    case notDetermined = "Not requested"
    case denied = "Not granted"
    case authorized = "Granted"

    var isGranted: Bool { self == .authorized }
}

@MainActor
final class Permissions: ObservableObject {
    private static let accessibilityPromptDelayNanoseconds: UInt64 = 500_000_000

    @Published private(set) var microphone: PermissionStatus = .notDetermined
    @Published private(set) var accessibility: PermissionStatus = .notDetermined

    init() {
        refresh()
    }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = .authorized
        case .denied, .restricted:
            microphone = .denied
        case .notDetermined:
            microphone = .notDetermined
        @unknown default:
            microphone = .denied
        }

        accessibility = AXIsProcessTrusted() ? .authorized : .denied
    }

    func requestMicrophone(completion: (@Sendable () -> Void)? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                completion?()
            }
        }
    }

    func requestAccessibility() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.accessibilityPromptDelayNanoseconds)
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            self.refresh()
        }
    }

    func requestInitialIfNeeded() {
        refresh()
        if microphone == .notDetermined {
            requestMicrophone { [weak self] in
                Task { @MainActor in
                    self?.requestAccessibilityIfNeeded()
                }
            }
            return
        }

        requestAccessibilityIfNeeded()
    }

    private func requestAccessibilityIfNeeded() {
        refresh()
        if accessibility != .authorized {
            requestAccessibility()
        }
    }
}
