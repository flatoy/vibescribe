import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

@MainActor
public final class VibeScribeApp: NSObject, NSApplicationDelegate {
    public static func main() {
        let app = NSApplication.shared
        let delegate = VibeScribeApp()
        app.delegate = delegate
        app.run()
    }

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
    private var recordingSession: RecordingSession!
    private var cancellables = Set<AnyCancellable>()
    private let clipboardRestoreDelay: TimeInterval = 0.2

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMenuBuilder.build()

        transcript = TranscriptBuffer()
        permissions = Permissions()
        preferences = Preferences()
        logger = Logger()
        audioCapture = AudioCaptureController()
        deepgramClient = DeepgramClient(
            onTranscriptEvent: { [weak self] text, isFinal in
                Task { @MainActor in
                    self?.recordingSession.handleTranscriptEvent(text, isFinal: isFinal)
                }
            },
            onLog: { [weak self] message, level in
                Task { @MainActor in
                    self?.logger.append(message, level: level)
                }
            }
        )

        recordingSession = RecordingSession(
            audioCapture: audioCapture,
            transcription: deepgramClient,
            transcript: transcript,
            logger: logger
        )
        recordingSession.onFinalized = { [weak self] text in
            self?.pasteFinalTranscript(text)
        }
        recordingSession.onMissingApiKey = { [weak self] in
            self?.openMainWindow()
        }

        mainWindowController = MainWindowController(
            recordingSession: recordingSession,
            transcript: transcript,
            permissions: permissions,
            preferences: preferences,
            logger: logger
        )
        overlayWindowController = OverlayWindowController(recordingSession: recordingSession)
        languagePickerWindowController = LanguagePickerWindowController(
            preferences: preferences,
            logger: logger
        )

        recordingSession.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                if state == .recording {
                    self.overlayWindowController.show()
                } else {
                    self.overlayWindowController.hide()
                }
            }
            .store(in: &cancellables)

        hotkeyCoordinator = HotkeyCoordinator(scheduler: DispatchHotkeyScheduler())
        hotkeyCoordinator.onIntent = { [weak self] intent in
            self?.handle(intent: intent)
        }

        hotkeyListener = HotkeyListener(hotkey: .pushToTalkDefault)
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

    private func handle(intent: HotkeyIntent) {
        switch intent {
        case .startRecording:
            recordingSession.start(apiKey: preferences.apiKey, language: preferences.deepgramLanguage)
        case .stopRecording:
            recordingSession.stop()
        case .cancelRecording:
            recordingSession.cancel()
        case .openLanguagePicker:
            languagePickerWindowController.show()
        }
    }

    private func pasteFinalTranscript(_ text: String) {
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
