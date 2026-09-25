import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let recordingSession: RecordingSession
    private let transcript: TranscriptBuffer
    private let permissions: Permissions
    private let preferences: Preferences
    private let logger: Logger
    private let modelSetup: WhisperModelSetup
    private var window: NSWindow?

    init(
        recordingSession: RecordingSession,
        transcript: TranscriptBuffer,
        permissions: Permissions,
        preferences: Preferences,
        logger: Logger,
        modelSetup: WhisperModelSetup
    ) {
        self.recordingSession = recordingSession
        self.transcript = transcript
        self.permissions = permissions
        self.preferences = preferences
        self.logger = logger
        self.modelSetup = modelSetup
    }

    func show() {
        if window == nil {
            let rootView = MainView(
                recordingSession: recordingSession,
                transcript: transcript,
                permissions: permissions,
                preferences: preferences,
                logger: logger,
                modelSetup: modelSetup
            )
            let hosting = NSHostingController(rootView: rootView)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "VibeScribe"
            window.contentViewController = hosting
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self

            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
