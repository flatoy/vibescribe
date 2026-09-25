import AppKit
import Combine
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let context: AppContext
    private let navigation = OnboardingNavigation()
    private var window: NSWindow?
    /// Called when the window opens or closes.
    var onVisibilityChanged: () -> Void = {}
    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { window != nil }

    init(context: AppContext) {
        self.context = context
        super.init()
        navigation.onFinish = { [weak self] in self?.finish() }
        context.history.$last
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] entry in
                guard let self, self.navigation.step == .practice, self.navigation.practiceResult == nil else { return }
                self.navigation.practiceResult = entry
            }
            .store(in: &cancellables)
    }

    func show() {
        if window == nil {
            if context.models.active.isReady || context.models.active.isRunning {
                navigation.step = context.models.active.isReady ? .practice : .model
                if !allPermissionsGranted { navigation.step = .permissions }
            } else {
                navigation.step = .welcome
            }
            window = makeWindow()
            context.permissions.beginPolling()
            onVisibilityChanged()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        context.permissions.endPolling()
        window = nil
        onVisibilityChanged()
    }

    private var allPermissionsGranted: Bool {
        let permissions = context.permissions
        return permissions.microphone.isGranted && permissions.inputMonitoring.isGranted && permissions.accessibility.isGranted
    }

    private func finish() {
        context.preferences.hasCompletedOnboarding = true
        context.logger.append("Setup finished.")
        close()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: OnboardingView(context: context, navigation: navigation))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.setContentSize(OnboardingView.size)
        window.title = "Set up VibeScribe"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x1E / 255, green: 0x1E / 255, blue: 0x21 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}
