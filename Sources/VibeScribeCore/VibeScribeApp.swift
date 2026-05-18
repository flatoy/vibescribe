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
    private var hotkeyCoordinator: HotkeyCoordinator!
    private var audioCapture: AudioCaptureController!
    private var deepgramClient: DeepgramClient!
    private let clipboardRestoreDelay: TimeInterval = 0.2

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

        hotkeyCoordinator = HotkeyCoordinator(scheduler: DispatchHotkeyScheduler())
        hotkeyCoordinator.onIntent = { [weak self] intent in
            self?.handle(intent: intent)
        }

        hotkeyListener = HotkeyListener(hotkey: appState.hotkey)
        hotkeyListener.onKeyDown = { [weak self] in
            self?.hotkeyCoordinator.primaryDown(at: CACurrentMediaTime())
        }
        hotkeyListener.onKeyUp = { [weak self] in
            self?.hotkeyCoordinator.primaryUp(at: CACurrentMediaTime())
        }
        hotkeyListener.start()

        languagePickerHotkeyListener = HotkeyListener(hotkey: .languagePickerDefault)
        languagePickerHotkeyListener.onKeyDown = { [weak self] in
            self?.hotkeyCoordinator.comboTriggered()
        }
        languagePickerHotkeyListener.start()

        menuBarController = MenuBarController(
            appState: appState,
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

        cancelRecording()
        appState.statusMessage = "Input changed. Press and hold Option to resume."
        appState.addLog("Recording stopped because the input device changed.", level: .warning)
    }

    private func handle(intent: HotkeyIntent) {
        switch intent {
        case .startRecording:
            startRecording()
        case .stopRecording:
            stopRecording()
        case .cancelRecording:
            cancelRecording()
        case .openLanguagePicker:
            languagePickerWindowController.show()
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

            audioCapture.onBuffer = { [weak self] buffer in
                self?.deepgramClient.sendAudio(buffer: buffer)
            }

            appState.isRecording = true
            appState.statusMessage = "Listening..."
            overlayWindowController.show()
            appState.addLog("Language: \(appState.deepgramLanguage.displayName) (\(appState.deepgramLanguage.deepgramCode)).", level: .info)
            appState.addLog("Listening started.", level: .info)
        } catch {
            appState.statusMessage = "Failed to start audio capture: \(error.localizedDescription)"
            appState.addLog("Failed to start audio capture: \(error.localizedDescription)", level: .error)
        }
    }

    private func stopRecording() {
        guard appState.isRecording else { return }

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

    private func cancelRecording() {
        guard appState.isRecording else { return }
        audioCapture.stop()
        deepgramClient.disconnect()
        appState.isRecording = false
        overlayWindowController.hide()
        appState.statusMessage = "Idle"
        appState.resetTranscript()
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
