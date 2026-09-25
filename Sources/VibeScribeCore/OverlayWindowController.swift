import AppKit
import Combine
import SwiftUI

/// A click-through panel below the menu bar that hosts the overlay pill.
@MainActor
final class OverlayWindowController {
    private let model: OverlayModel
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 620, height: 64)

    init(model: OverlayModel) {
        self.model = model
        cancellable = model.$phase
            .map { $0 != .hidden }
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible { self?.show() } else { self?.scheduleOrderOut() }
            }
    }

    private func show() {
        hideWork?.cancel()
        hideWork = nil
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            panel.setFrame(frame(on: screen), display: false)
        }
        panel.orderFrontRegardless()
    }

    /// The pill animates out in SwiftUI; the panel leaves once that has finished.
    private func scheduleOrderOut() {
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        return panel
    }

    private func frame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - Self.size.width / 2,
            y: visible.maxY - Self.size.height - 10,
            width: Self.size.width,
            height: Self.size.height
        )
    }
}
