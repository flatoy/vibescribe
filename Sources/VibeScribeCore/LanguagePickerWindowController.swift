import AppKit
import Carbon
import SwiftUI

@MainActor
final class LanguagePickerWindowController {
    private let appState: AppState
    private let model: LanguagePickerModel
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var isShowing = false
    private var previousFrontmostApp: NSRunningApplication?

    init(appState: AppState) {
        self.appState = appState
        self.model = LanguagePickerModel()
        self.model.onCommit = { [weak self] language in
            self?.commit(language: language)
        }
        self.model.onCancel = { [weak self] in
            self?.hide()
        }
    }

    var isVisible: Bool { isShowing }

    func toggle() {
        if isShowing {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        guard !isShowing else { return }

        model.reset()

        let ownBundleID = Bundle.main.bundleIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != ownBundleID {
            previousFrontmostApp = frontmost
        } else {
            previousFrontmostApp = nil
        }

        NSApp.activate(ignoringOtherApps: true)

        let target = targetFrame(panelSize: panel.frame.size)
        let offscreen = offscreenFrame(panelSize: panel.frame.size)

        panel.alphaValue = 0
        panel.setFrame(offscreen, display: false)
        panel.makeKeyAndOrderFront(nil)
        isShowing = true
        installEventHooks()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide(restoreFocus: Bool = true) {
        guard let panel, isShowing else { return }
        isShowing = false
        removeEventHooks()

        let appToRestore = restoreFocus ? previousFrontmostApp : nil
        previousFrontmostApp = nil

        let frame = panel.frame
        let offscreen = CGRect(x: frame.minX, y: frame.minY + 16, width: frame.width, height: frame.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(offscreen, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShowing else { return }
                self.panel?.orderOut(nil)
            }
        }

        if let appToRestore, !appToRestore.isTerminated {
            appToRestore.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func commit(language: DeepgramLanguage) {
        appState.deepgramLanguage = language
        appState.addLog("Language set to \(language.displayName) (\(language.deepgramCode)).", level: .info)
        hide()
    }

    private func makePanel() -> NSPanel {
        let view = LanguagePickerView(model: model)
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 380, height: 340)

        let panel = KeyableLanguagePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        if let contentView = panel.contentView {
            hosting.view.frame = contentView.bounds
            hosting.view.autoresizingMask = [.width, .height]
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func installEventHooks() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            guard self.isShowing else { return event }
            guard self.panel?.isKeyWindow == true else { return event }

            switch Int(event.keyCode) {
            case kVK_UpArrow:
                self.model.moveHighlight(by: -1)
                return nil
            case kVK_DownArrow:
                self.model.moveHighlight(by: 1)
                return nil
            case kVK_PageUp:
                self.model.moveHighlight(by: -5)
                return nil
            case kVK_PageDown:
                self.model.moveHighlight(by: 5)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.model.commit()
                return nil
            case kVK_Escape:
                self.model.cancel()
                return nil
            default:
                return event
            }
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hide(restoreFocus: false)
            }
        }
    }

    private func removeEventHooks() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
    }

    private func targetFrame(panelSize: CGSize) -> CGRect {
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            return CGRect(origin: .zero, size: panelSize)
        }
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.maxY - panelSize.height - 80
        return CGRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }

    private func offscreenFrame(panelSize: CGSize) -> CGRect {
        guard let screenFrame = NSScreen.main?.visibleFrame else {
            return CGRect(origin: .zero, size: panelSize)
        }
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.maxY + 12
        return CGRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
    }
}

private final class KeyableLanguagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
