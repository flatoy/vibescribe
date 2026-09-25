import AppKit
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

    private var context: AppContext!
    private var preferences: Preferences!
    private var permissions: Permissions!
    private var logger: Logger!
    private var models: SpeechModelLibrary!
    private var history: TranscriptHistory!
    private var recordingSession: RecordingSession!
    private var whisperKitClient: WhisperKitClient!
    private var overlay: OverlayModel!
    private var overlayWindowController: OverlayWindowController!
    private var languagePickerWindowController: LanguagePickerWindowController!
    private var settingsWindowController: SettingsWindowController!
    private var onboardingWindowController: OnboardingWindowController!
    private var menuBarController: MenuBarController!
    private var permissionHelper: PermissionHelperController!
    private var hotkeyCoordinator: HotkeyCoordinator!
    private var hotkeyListener: HotkeyListener?
    private var languagePickerHotkeyListener: HotkeyListener?
    private var escapeListener: HotkeyListener?
    private var isRecordingShortcut = false
    /// The app that was frontmost when recording started; transcripts go there.
    private var targetAppName: String?
    /// The last app other than VibeScribe, for "Paste again".
    private var lastExternalApp: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = AppMenuBuilder.build()

        logger = Logger()
        preferences = Preferences()
        permissions = Permissions()
        let client = WhisperKitClient(
            modelFolder: WhisperModelLocator.modelFolder(for: preferences.speechModel),
            onLog: { [weak self] message, level in
                Task { @MainActor in self?.logger.append(message, level: level) }
            }
        )
        client.setVocabulary(preferences.vocabulary)
        whisperKitClient = client
        models = SpeechModelLibrary(preferences: preferences, logger: logger, client: client)
        history = TranscriptHistory(fileURL: TranscriptHistory.defaultURL())
        history.prune(retention: preferences.historyRetention)
        recordingSession = RecordingSession(
            audioCapture: AudioCaptureController(),
            transcription: client,
            transcript: TranscriptBuffer(),
            logger: logger
        )
        let status = AppStatus(
            session: recordingSession,
            models: models,
            permissions: permissions,
            preferences: preferences
        )
        let recorder = HotkeyRecorder()
        context = AppContext(
            preferences: preferences,
            permissions: permissions,
            models: models,
            history: history,
            logger: logger,
            status: status,
            microphones: MicrophoneMonitor(),
            loginItem: LoginItem(),
            recorder: recorder,
            output: TextOutput(preferences: preferences, logger: logger)
        )

        overlay = OverlayModel(level: recordingSession.level)
        overlayWindowController = OverlayWindowController(model: overlay)
        languagePickerWindowController = LanguagePickerWindowController(preferences: preferences, logger: logger)
        settingsWindowController = SettingsWindowController(context: context)
        onboardingWindowController = OnboardingWindowController(context: context)
        menuBarController = MenuBarController(context: context, session: recordingSession)

        permissionHelper = PermissionHelperController(permissions: permissions)
        SystemSettings.didOpen = { [weak self] pane in
            switch pane {
            case .inputMonitoring: self?.permissionHelper.show(.inputMonitoring)
            case .accessibility: self?.permissionHelper.show(.accessibility)
            case .microphone, .storage: break
            }
        }
        settingsWindowController.onVisibilityChanged = { [weak self] in self?.updateActivationPolicy() }
        onboardingWindowController.onVisibilityChanged = { [weak self] in self?.updateActivationPolicy() }
        context.openLanguagePicker = { [weak self] mode in self?.languagePickerWindowController.show(mode: mode) }
        context.openSettings = { [weak self] page in self?.settingsWindowController.show(page: page) }
        context.openSetup = { [weak self] in self?.onboardingWindowController.show() }
        context.pasteAgain = { [weak self] entry in self?.pasteAgain(entry) }

        recordingSession.onEnded = { [weak self] end in self?.handle(end: end) }
        recorder.onActiveChanged = { [weak self] active in
            self?.isRecordingShortcut = active
            self?.configureHotkeys()
        }
        recorder.onRecord = { [weak self] target, hotkey in
            guard let self else { return }
            switch target {
            case .pushToTalk: self.preferences.pushToTalkHotkey = hotkey
            case .languagePicker: self.preferences.languagePickerHotkey = hotkey
            }
            self.logger.append("Shortcut changed to \(hotkey.displayName).")
        }

        hotkeyCoordinator = HotkeyCoordinator(scheduler: DispatchHotkeyScheduler())
        hotkeyCoordinator.onIntent = { [weak self] intent in self?.handle(intent: intent) }
        observePreferences()
        observeFrontmostApp()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        logger.append("VibeScribe launched.", level: .info)
        startSetupFlow()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        permissions.refresh()
    }

    // MARK: Windows

    /// A menu bar app while idle; a regular app (Dock, ⌘Tab) while one of its windows is open.
    private func updateActivationPolicy() {
        let hasWindow = settingsWindowController.isVisible || onboardingWindowController.isVisible
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if hasWindow {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.show()
    }

    // MARK: Launch

    private func startSetupFlow() {
        if !preferences.hasCompletedOnboarding,
           WhisperModelLocator.isComplete(models.active.modelFolder),
           permissions.microphone.isGranted, permissions.accessibility.isGranted {
            // People upgrading from an earlier version are already set up.
            preferences.hasCompletedOnboarding = true
        }
        // Verifying files already on disk needs no consent; downloading waits for the setup window.
        if preferences.hasCompletedOnboarding || WhisperModelLocator.isComplete(models.active.modelFolder) {
            models.start()
        }
        if !preferences.hasCompletedOnboarding {
            onboardingWindowController.show()
        }
    }

    // MARK: Preferences

    private func observePreferences() {
        Publishers.CombineLatest3(
            preferences.$pushToTalkHotkey,
            preferences.$languagePickerHotkey,
            preferences.$isShortcutPaused
        )
        .dropFirst()
        .sink { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.configureHotkeys() }
        }
        .store(in: &cancellables)
        configureHotkeys()

        preferences.$triggerMode
            .sink { [weak self] mode in
                // Switching modes resets the coordinator, so end any recording cleanly first.
                if self?.recordingSession.isActive == true {
                    self?.recordingSession.cancel()
                    self?.overlay.show(.cancelled)
                }
                self?.hotkeyCoordinator.mode = switch mode {
                case .holdOrTap: .holdOrTap
                case .holdOnly: .holdOnly
                case .tapOnly: .tapOnly
                }
            }
            .store(in: &cancellables)

        preferences.$vocabulary
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] words in self?.whisperKitClient.setVocabulary(words) }
            .store(in: &cancellables)

        preferences.$historyRetention
            .dropFirst()
            .sink { [weak self] retention in
                guard let self else { return }
                if retention == .off {
                    self.history.clear()
                } else {
                    self.history.prune(retention: retention)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(preferences.$language, preferences.$pushToTalkHotkey)
            .sink { [weak self] language, hotkey in
                self?.overlay.languageBadge = language == .automatic ? nil : language.badge
                self?.overlay.shortcutKeycaps = hotkey.keycaps.map { $0.replacingOccurrences(of: "Right ", with: "") }
            }
            .store(in: &cancellables)

        recordingSession.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.setEscapeListening(state != .idle) }
            .store(in: &cancellables)
    }

    private func configureHotkeys() {
        hotkeyListener?.stop()
        languagePickerHotkeyListener?.stop()
        hotkeyListener = nil
        languagePickerHotkeyListener = nil
        guard !preferences.isShortcutPaused, !isRecordingShortcut else {
            hotkeyCoordinator.reset()
            return
        }

        let listener = HotkeyListener(hotkey: preferences.pushToTalkHotkey)
        listener.onKeyDown = { [weak self] in self?.hotkeyCoordinator.primaryDown(at: CACurrentMediaTime()) }
        listener.onKeyUp = { [weak self] in self?.hotkeyCoordinator.primaryUp(at: CACurrentMediaTime()) }
        listener.start()
        hotkeyListener = listener

        let picker = HotkeyListener(hotkey: preferences.languagePickerHotkey)
        picker.onKeyDown = { [weak self] in self?.hotkeyCoordinator.comboTriggered() }
        picker.onKeyUp = { [weak self] in self?.hotkeyCoordinator.comboReleased() }
        picker.start()
        languagePickerHotkeyListener = picker
    }

    private func setEscapeListening(_ listening: Bool) {
        guard listening else {
            escapeListener?.stop()
            escapeListener = nil
            return
        }
        guard escapeListener == nil else { return }
        let listener = HotkeyListener(hotkey: .escape)
        listener.onKeyDown = { [weak self] in self?.escapePressed() }
        listener.start()
        escapeListener = listener
    }

    private func escapePressed() {
        if hotkeyCoordinator.isRecording {
            hotkeyCoordinator.cancelRequested()
        } else if recordingSession.state == .finalizing {
            recordingSession.cancel()
            overlay.show(.cancelled)
        }
    }

    private func observeFrontmostApp() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0 != NSRunningApplication.current }
            .sink { [weak self] app in self?.lastExternalApp = app }
            .store(in: &cancellables)
    }

    // MARK: Recording

    private func handle(intent: HotkeyIntent) {
        switch intent {
        case .startRecording:
            startRecording()
        case .handsFree:
            if recordingSession.isRecording {
                overlay.showListening(handsFree: true)
            }
        case .stopRecording:
            guard recordingSession.isRecording else { return }
            recordingSession.stop()
            if preferences.playSounds { Sounds.play(.stop) }
            overlay.showTranscribing()
        case .cancelRecording:
            guard recordingSession.isActive else { return }
            recordingSession.cancel()
            overlay.show(.cancelled)
        case .openLanguagePicker:
            // A recording started by pressing the dictation key first was just cancelled; don't flash it.
            overlay.hide()
            languagePickerWindowController.show()
        }
    }

    private func startRecording() {
        let setup = models.active
        guard setup.isReady else {
            resetCoordinatorSoon()
            switch setup.state {
            case _ where !setup.isRunning:
                preferences.hasCompletedOnboarding ? settingsWindowController.show(page: .model) : onboardingWindowController.show()
            default:
                break
            }
            overlay.show(.loading(setup.state == .preparing ? nil : setup.progress), for: 1.8)
            return
        }
        permissions.refresh()
        guard permissions.microphone == .authorized else {
            // Without access macOS supplies silence, so don't record at all.
            resetCoordinatorSoon()
            logger.append("Recording blocked: microphone access is \(permissions.microphone.rawValue.lowercased()).", level: .warning)
            if permissions.microphone == .notDetermined { permissions.requestMicrophone() }
            overlay.show(.microphoneOff, for: 2.5)
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        targetAppName = frontmost == NSRunningApplication.current ? "VibeScribe" : frontmost?.localizedName
        if recordingSession.start(language: preferences.language, inputDeviceUID: preferences.microphoneUID) {
            if preferences.playSounds { Sounds.play(.start) }
            overlay.showListening(handsFree: false)
        } else {
            resetCoordinatorSoon()
        }
    }

    private func handle(end: SessionEnd) {
        switch end {
        case .transcript(let transcript):
            let result = context.output.deliver(transcript.text)
            history.add(
                HistoryEntry(
                    text: transcript.text,
                    languageCode: transcript.languageCode,
                    duration: transcript.duration,
                    appName: result == .pasted ? targetAppName : "Clipboard"
                ),
                retention: preferences.historyRetention
            )
            overlay.show(result == .pasted ? .pasted(words: transcript.wordCount) : .copied, for: result == .copied ? 2.2 : 1.3)
        case .noSpeech:
            overlay.show(.noSpeech)
        case .failed(let message):
            overlay.show(.failed(message), for: 2.5)
        case .couldNotStart(let message):
            resetCoordinatorSoon()
            overlay.show(permissions.microphone == .authorized ? .failed(message) : .microphoneOff, for: 2.5)
        case .interrupted:
            hotkeyCoordinator.reset()
            overlay.show(.cancelled)
        }
    }

    private func resetCoordinatorSoon() {
        DispatchQueue.main.async { [weak self] in self?.hotkeyCoordinator.reset() }
    }

    private func pasteAgain(_ entry: HistoryEntry) {
        guard let app = lastExternalApp, !app.isTerminated else {
            context.output.copy(entry.text)
            overlay.show(.copied, for: 2.2)
            return
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let result = self.context.output.deliver(entry.text)
            self.overlay.show(result == .pasted ? .pasted(words: entry.text.split(separator: " ").count) : .copied)
        }
    }
}
