import AppKit
import ApplicationServices
import Carbon
import SwiftUI

@MainActor
public final class VibeScribeApp: NSObject, NSApplicationDelegate {
    public static func main() {
        let app = NSApplication.shared
        let delegate = VibeScribeApp()
        app.delegate = delegate
        app.run()
    }

    private var appState: AppState!
    private var menuBarController: MenuBarController!
    private var mainWindowController: MainWindowController!
    private var overlayWindowController: OverlayWindowController!
    private var hotkeyListener: HotkeyListener!
    private var audioCapture: AudioCaptureController!
    private var deepgramClient: DeepgramClient!
    private var liveTextInjection: LiveTextInjectionController!
    private var stopWorkItem: DispatchWorkItem?
    private var hotkeyPressedAt: TimeInterval?
    private var isLatchedRecording = false
    private var streamWhileRecordingForSession = false
    private let hotkeyTapThreshold: TimeInterval = 0.25
    private let stopDelay: TimeInterval = 0.2
    private let clipboardRestoreDelay: TimeInterval = 0.2

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMenuBuilder.build()

        appState = AppState()
        audioCapture = AudioCaptureController()
        liveTextInjection = LiveTextInjectionController(
            onLog: { [weak self] message, level in
                self?.appState.addLog(message, level: level)
            }
        )
        deepgramClient = DeepgramClient(
            onTranscriptEvent: { [weak self] event in
                Task { @MainActor in
                    self?.handleTranscriptEvent(event)
                }
            },
            onLog: { [weak self] message, level in
                Task { @MainActor in
                    self?.appState.addLog(message, level: level)
                }
            }
        )

        mainWindowController = MainWindowController(appState: appState)
        overlayWindowController = OverlayWindowController(appState: appState)

        hotkeyListener = HotkeyListener(hotkey: appState.hotkey)
        hotkeyListener.onKeyDown = { [weak self] in
            self?.handleHotkeyDown()
        }
        hotkeyListener.onKeyUp = { [weak self] in
            self?.handleHotkeyUp()
        }
        hotkeyListener.start()

        menuBarController = MenuBarController(
            onOpenMain: { [weak self] in self?.openMainWindow() },
            onQuit: { NSApp.terminate(nil) }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        appState.requestInitialPermissionsIfNeeded()
        appState.addLog("VibeScribe launched.", level: .info)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        liveTextInjection.endSession()
    }

    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        appState.refreshPermissions()
    }

    private func openMainWindow() {
        mainWindowController.show()
    }

    private func handleTranscriptEvent(_ event: TranscriptEvent) {
        appState.handleTranscriptEvent(event)
        if streamWhileRecordingForSession {
            liveTextInjection.enqueueRewrite(to: appState.displayTranscript, isFinal: event.isFinal)
        }
    }

    private func startRecording() {
        guard !appState.isRecording else { return }

        let apiKey = appState.apiKey.trimmed
        guard !apiKey.isEmpty else {
            appState.statusMessage = "Add a Deepgram API key in Settings."
            appState.addLog("Missing API key. Open Settings to add one.", level: .warning)
            openMainWindow()
            return
        }

        do {
            appState.resetTranscript()
            let format = try audioCapture.start()
            appState.addLog("Audio capture started (\(format.sampleRate) Hz, \(format.channels) ch).", level: .info)
            deepgramClient.connect(apiKey: apiKey, format: format, language: appState.deepgramLanguage)
            streamWhileRecordingForSession = appState.liveTranscriptionEnabled
            if streamWhileRecordingForSession {
                let rewriteStyle = rewriteStyleForFrontmostApp()
                _ = liveTextInjection.startSession(rewriteStyle: rewriteStyle)
            }

            audioCapture.onBuffer = { [weak self] buffer in
                self?.deepgramClient.sendAudio(buffer: buffer)
            }

            appState.isRecording = true
            appState.statusMessage = "Listening..."
            overlayWindowController.show()
            appState.addLog("Language: \(appState.deepgramLanguage.displayName) (\(appState.deepgramLanguage.deepgramCode)).", level: .info)
            appState.addLog("Listening started.", level: .info)
        } catch {
            liveTextInjection.endSession()
            streamWhileRecordingForSession = false
            isLatchedRecording = false
            appState.statusMessage = "Failed to start audio capture: \(error.localizedDescription)"
            appState.addLog("Failed to start audio capture: \(error.localizedDescription)", level: .error)
        }
    }

    private func rewriteStyleForFrontmostApp() -> LiveTextInjectionController.RewriteStyle {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if bundleID == "com.apple.Notes" {
            appState.addLog("Using Notes-safe live mode: append during speech, rewrite on final chunks.", level: .info)
            return .appendDuringInterim
        }
        return .replaceInPlace
    }

    private func stopRecording() {
        guard appState.isRecording else { return }

        cancelPendingStop()
        isLatchedRecording = false
        audioCapture.stop()
        appState.isRecording = false
        overlayWindowController.hide()
        appState.statusMessage = "Finalizing..."

        deepgramClient.closeStream { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let textToPaste: String
                if self.streamWhileRecordingForSession {
                    self.liveTextInjection.flush()
                    textToPaste = self.liveTextInjection.fallbackText(for: self.appState.displayTranscript)
                } else {
                    textToPaste = self.appState.displayTranscript
                }
                self.liveTextInjection.endSession()
                self.streamWhileRecordingForSession = false
                self.appState.statusMessage = "Idle"
                self.appState.addLog("Listening stopped.", level: .info)
                if !textToPaste.trimmed.isEmpty {
                    self.pasteTranscript(textToPaste)
                }
            }
        }
    }

    private func scheduleStopRecording() {
        cancelPendingStop()
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopRecording()
        }
        stopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + stopDelay, execute: workItem)
    }

    private func cancelPendingStop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
    }

    private func handleHotkeyDown() {
        hotkeyPressedAt = CACurrentMediaTime()
        if isLatchedRecording {
            return
        }
        cancelPendingStop()
        startRecording()
    }

    private func handleHotkeyUp() {
        let now = CACurrentMediaTime()
        let pressedAt = hotkeyPressedAt
        hotkeyPressedAt = nil

        let duration = pressedAt.map { now - $0 } ?? 0
        let isTap = duration <= hotkeyTapThreshold

        if isTap {
            if isLatchedRecording {
                isLatchedRecording = false
                scheduleStopRecording()
            } else {
                if !appState.isRecording {
                    startRecording()
                }
                if appState.isRecording {
                    isLatchedRecording = true
                    cancelPendingStop()
                }
            }
            return
        }

        if isLatchedRecording {
            return
        }
        scheduleStopRecording()
    }

    private func pasteTranscript(_ rawText: String) {
        guard !rawText.trimmed.isEmpty else {
            appState.addLog("No transcript to paste.", level: .warning)
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(rawText, forType: .string)
        appState.addLog("Transcript copied to clipboard.", level: .info)

        if !AXIsProcessTrusted() {
            appState.addLog("Accessibility permission not granted. Enable it to allow paste automation.", level: .warning)
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            appState.addLog("Failed to create CGEventSource for paste.", level: .error)
            snapshot.restore(to: pasteboard)
            return
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        appState.addLog("Paste command sent (Cmd+V).", level: .info)

        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            snapshot.restore(to: pasteboard)
        }
    }
}
