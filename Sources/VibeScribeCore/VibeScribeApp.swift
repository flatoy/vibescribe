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
    private var languagePickerWindowController: LanguagePickerWindowController!
    private var hotkeyListener: HotkeyListener!
    private var languagePickerHotkeyListener: HotkeyListener!
    private var audioCapture: AudioCaptureController!
    private var deepgramClient: DeepgramClient!
    private var stopWorkItem: DispatchWorkItem?
    private var hotkeyPressedAt: TimeInterval?
    private var isLatchedRecording = false
    private var pendingOverlayShowToken: UUID?
    private let hotkeyTapThreshold: TimeInterval = 0.25
    private let stopDelay: TimeInterval = 0.2
    private let clipboardRestoreDelay: TimeInterval = 0.2
    private let overlayShowDelay: TimeInterval = 0.09

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMenuBuilder.build()

        appState = AppState()
        audioCapture = AudioCaptureController()
        audioCapture.onConfigurationChanged = { [weak self] in
            Task { @MainActor in
                self?.handleAudioInputConfigurationChanged()
            }
        }
        deepgramClient = DeepgramClient(
            onTranscriptEvent: { [weak self] text, isFinal in
                Task { @MainActor in
                    self?.appState.handleTranscript(text, isFinal: isFinal)
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
        languagePickerWindowController = LanguagePickerWindowController(appState: appState)

        hotkeyListener = HotkeyListener(hotkey: appState.hotkey)
        hotkeyListener.onKeyDown = { [weak self] in
            self?.handleHotkeyDown()
        }
        hotkeyListener.onKeyUp = { [weak self] in
            self?.handleHotkeyUp()
        }
        hotkeyListener.start()

        languagePickerHotkeyListener = HotkeyListener(hotkey: .languagePickerDefault)
        languagePickerHotkeyListener.onKeyDown = { [weak self] in
            self?.handleLanguagePickerHotkey()
        }
        languagePickerHotkeyListener.start()

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
    }

    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        appState.refreshPermissions()
    }

    private func openMainWindow() {
        mainWindowController.show()
    }

    private func handleAudioInputConfigurationChanged() {
        appState.addLog("Audio input changed. Capture engine reset.", level: .warning)
        guard appState.isRecording else {
            appState.statusMessage = "Audio input changed. Ready."
            return
        }

        cancelPendingStop()
        isLatchedRecording = false
        pendingOverlayShowToken = nil
        deepgramClient.disconnect()
        appState.isRecording = false
        overlayWindowController.hide()
        appState.statusMessage = "Input changed. Press and hold Option to resume."
        appState.addLog("Recording stopped because the input device changed.", level: .warning)
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

            audioCapture.onBuffer = { [weak self] buffer in
                self?.deepgramClient.sendAudio(buffer: buffer)
            }

            appState.isRecording = true
            appState.statusMessage = "Listening..."
            scheduleOverlayShow()
            appState.addLog("Language: \(appState.deepgramLanguage.displayName) (\(appState.deepgramLanguage.deepgramCode)).", level: .info)
            appState.addLog("Listening started.", level: .info)
        } catch {
            isLatchedRecording = false
            appState.statusMessage = "Failed to start audio capture: \(error.localizedDescription)"
            appState.addLog("Failed to start audio capture: \(error.localizedDescription)", level: .error)
        }
    }

    private func stopRecording() {
        guard appState.isRecording else { return }

        cancelPendingStop()
        isLatchedRecording = false
        pendingOverlayShowToken = nil
        audioCapture.stop()
        appState.isRecording = false
        overlayWindowController.hide()
        appState.statusMessage = "Finalizing..."

        deepgramClient.closeStream { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.appState.statusMessage = "Idle"
                self.appState.addLog("Listening stopped.", level: .info)
                self.pasteFinalTranscript()
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

    private func handleLanguagePickerHotkey() {
        if appState.isRecording {
            cancelRecording()
        }
        languagePickerWindowController.show()
    }

    private func cancelRecording() {
        guard appState.isRecording else { return }
        cancelPendingStop()
        isLatchedRecording = false
        hotkeyPressedAt = nil
        pendingOverlayShowToken = nil
        audioCapture.stop()
        deepgramClient.disconnect()
        appState.isRecording = false
        overlayWindowController.hide()
        appState.statusMessage = "Idle"
        appState.resetTranscript()
    }

    private func scheduleOverlayShow() {
        let token = UUID()
        pendingOverlayShowToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayShowDelay) { [weak self] in
            guard let self else { return }
            guard self.pendingOverlayShowToken == token else { return }
            guard self.appState.isRecording else { return }
            self.pendingOverlayShowToken = nil
            self.overlayWindowController.show()
        }
    }

    private func handleHotkeyUp() {
        guard let pressedAt = hotkeyPressedAt else { return }
        hotkeyPressedAt = nil

        let now = CACurrentMediaTime()
        let duration = now - pressedAt
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

    private func pasteFinalTranscript() {
        let finalText = appState.finalTranscript.trimmed
        let fallbackText = appState.lastTranscript.trimmed
        let text = finalText.isEmpty ? fallbackText : finalText
        guard !text.isEmpty else {
            appState.addLog("No transcript to paste.", level: .warning)
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return dataByType
        } ?? []
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { dataByType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
