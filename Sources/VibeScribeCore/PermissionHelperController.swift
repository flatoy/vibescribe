import AppKit
import SwiftUI

/// Keeps a small card beside System Settings while someone grants a permission,
/// so they can drag VibeScribe straight into the privacy list.
@MainActor
final class PermissionHelperController {
    private let permissions: Permissions
    private var panel: NSPanel?
    private var timer: Timer?
    private var kind: PermissionHelperKind?
    private var startedAt = Date()
    private var sawSettingsWindow = false
    /// The System Settings main window, so sheets and password prompts don't pull the card around.
    private var trackedWindow: Int?

    private static let settingsBundleID = "com.apple.systempreferences"
    private static let margin: CGFloat = 12

    init(permissions: Permissions) {
        self.permissions = permissions
    }

    /// Dragging only works for the packaged app; `swift run` has no bundle to drag.
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func show(_ kind: PermissionHelperKind) {
        guard isAvailable, !isGranted(kind) else { return }
        self.kind = kind
        startedAt = Date()
        sawSettingsWindow = false
        trackedWindow = nil
        panel?.orderOut(nil)
        panel = makePanel(kind)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        kind = nil
    }

    private func tick() {
        guard let kind, let panel else { return close() }
        permissions.refresh()
        if isGranted(kind) { return close() }

        let settingsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).isEmpty
        if sawSettingsWindow, !settingsRunning { return close() }
        if !sawSettingsWindow, Date().timeIntervalSince(startedAt) > 30 { return close() }

        // Only show while System Settings is in front: not over other apps or the password prompt.
        let settingsInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.settingsBundleID
        guard settingsInFront, let window = settingsMainWindow() else {
            panel.orderOut(nil)
            return
        }
        sawSettingsWindow = true
        let target = Self.placement(beside: window, size: panel.frame.size)
        if !panel.frame.equalTo(target) {
            panel.setFrame(target, display: true)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func isGranted(_ kind: PermissionHelperKind) -> Bool {
        switch kind {
        case .inputMonitoring: return permissions.inputMonitoring.isGranted
        case .accessibility: return permissions.accessibility.isGranted
        }
    }

    private func makePanel(_ kind: PermissionHelperKind) -> NSPanel {
        let view = PermissionHelperView(kind: kind, appURL: Bundle.main.bundleURL) { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PermissionHelperView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    /// Below the System Settings window, under its content area where the list is.
    /// Falls back to overlapping the window's bottom edge when there's no room below.
    static func placement(beside window: NSRect, size: NSSize) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(window) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? window
        var x = window.maxX - size.width - 40
        x = min(max(x, screen.minX + margin), screen.maxX - size.width - margin)
        var y = window.minY - size.height - margin
        if y < screen.minY + margin {
            y = window.minY + margin
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The System Settings main window in Cocoa screen coordinates: the one already followed,
    /// or else the largest. Window bounds are readable without Screen Recording permission.
    private func settingsMainWindow() -> NSRect? {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let windows: [(number: Int, rect: CGRect)] = info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == settings.processIdentifier,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 400, rect.height > 300 else { return nil }
            return (number, rect)
        }
        let chosen = windows.first { $0.number == trackedWindow }
            ?? windows.max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
        guard let chosen else { return nil }
        trackedWindow = chosen.number
        // Core Graphics measures from the top of the main display; Cocoa from the bottom.
        let mainHeight = NSScreen.screens.first?.frame.height ?? chosen.rect.maxY
        return NSRect(x: chosen.rect.minX, y: mainHeight - chosen.rect.maxY, width: chosen.rect.width, height: chosen.rect.height)
    }
}
