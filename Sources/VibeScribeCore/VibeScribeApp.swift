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
    private var transcript: TranscriptBuffer!
    private var permissions: Permissions!
    private var preferences: Preferences!
    private var logger: Logger!
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
        transcript = TranscriptBuffer()
        permissions = Permissions()
        preferences = Preferences()
        logger = Logger()
        audioCapture = AudioCaptureController()
        audioCapture.onConfigurationChanged = { [weak self] in
            Task { @MainActor in
                self?.handleAudioInputConfigurationChanged()
            }
        }
        deepgramClient = DeepgramClient(
            onTranscriptEvent: { [weak self] text, isFinal in
                Task { @MainActor in
                    self?.transcript.handle(text, isFinal: isFinal)
                }
            },
            onLog: { [weak self] message, level in
                Task { @MainActor in
                    self?.logger.append(message, level: level)
                }
            }
        )

        mainWindowController = MainWindowController(
            appState: appState,
            transcript: transcript,
            permissions: permissions,
            preferences: preferences,
            logger: logger
        )
        overlayWindowController = OverlayWindowController(appState: appState)
        languagePickerWindowController = LanguagePickerWindowController(
            preferences: preferences,
            logger: logger
        )

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
            preferences: preferences,
            onOpenMain: { [weak self] in self?.openMainWindow() },
            onQuit: { NSApp.terminate(nil) }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        permissions.requestInitialIfNeeded()
        logger.append("VibeScribe launched.", level: .info)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        permissions.refresh()
    }

    private func openMainWindow() {
        mainWindowController.show()
    }

    private func handleAudioInputConfigurationChanged() {
        logger.append("Audio input changed. Capture engine reset.", level: .warning)
        guard appState.isRecording else {
            appState.statusMessage = "Audio input changed. Ready."
            return
        }

        cancelRecording()
        appState.statusMessage = "Input changed. Press and hold Option to resume."
        logger.append("Recording stopped because the input device changed.", level: .warning)
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

        let apiKey = preferences.apiKey.trimmed
        guard !apiKey.isEmpty else {
            appState.statusMessage = "Add a Deepgram API key in Settings."
            logger.append("Missing API key. Open Settings to add one.", level: .warning)
            openMainWindow()
            return
        }

        do {
            transcript.reset()
            let format = try audioCapture.start()
            logger.append("Audio capture started (\(format.sampleRate) Hz, \(format.channels) ch).", level: .info)
            deepgramClient.connect(apiKey: apiKey, format: format, language: preferences.deepgramLanguage)

            audioCapture.onBuffer = { [weak self] buffer in
                self?.deepgramClient.sendAudio(buffer: buffer)
            }

            appState.isRecording = true
            appState.statusMessage = "Listening..."
            overlayWindowController.show()
            logger.append("Language: \(preferences.deepgramLanguage.displayName) (\(preferences.deepgramLanguage.deepgramCode)).", level: .info)
            logger.append("Listening started.", level: .info)
        } catch {
            appState.statusMessage = "Failed to start audio capture: \(error.localizedDescription)"
            logger.append("Failed to start audio capture: \(error.localizedDescription)", level: .error)
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
                self.logger.append("Listening stopped.", level: .info)
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
        transcript.reset()
    }

    private func pasteFinalTranscript() {
        let text = transcript.effectiveText
        guard !text.isEmpty else {
            logger.append("No transcript to paste.", level: .warning)
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.append("Transcript copied to clipboard.", level: .info)

        if !AXIsProcessTrusted() {
            logger.append("Accessibility permission not granted. Enable it to allow paste automation.", level: .warning)
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.append("Failed to create CGEventSource for paste.", level: .error)
            snapshot.restore(to: pasteboard)
            return
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        logger.append("Paste command sent (Cmd+V).", level: .info)

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
