import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let context: AppContext
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    /// Called when the window opens or closes.
    var onVisibilityChanged: () -> Void = {}

    var isVisible: Bool { window != nil }

    init(context: AppContext) {
        self.context = context
    }

    func show(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        if window == nil {
            window = makeWindow()
            context.permissions.beginPolling()
            onVisibilityChanged()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        context.recorder.stop()
        context.permissions.endPolling()
        window = nil
        onVisibilityChanged()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(context: context, navigation: navigation))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(SettingsView.size)
        window.title = "VibeScribe Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x1E / 255, green: 0x1E / 255, blue: 0x21 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("VibeScribeSettings")
        return window
    }
}
