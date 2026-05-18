import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let recordingSession: RecordingSession
    private var panel: NSPanel?
    private var isShowing = false
    private var animationID = UUID()

    init(recordingSession: RecordingSession) {
        self.recordingSession = recordingSession
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        isShowing = true
        animationID = UUID()

        guard let screenFrame = NSScreen.main?.visibleFrame else {
            panel.orderFrontRegardless()
            return
        }

        let target = targetFrame(in: screenFrame)
        let offscreen = offscreenFrame(in: screenFrame, width: target.width, height: target.height)

        panel.alphaValue = 0
        panel.setFrame(offscreen, display: false)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide() {
        guard let panel else { return }
        guard isShowing else { return }
        isShowing = false
        let hideID = animationID

        guard let screenFrame = NSScreen.main?.visibleFrame else {
            panel.orderOut(nil)
            return
        }

        let target = targetFrame(in: screenFrame)
        let offscreen = offscreenFrame(in: screenFrame, width: target.width, height: target.height)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(offscreen, display: true)
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.animationID == hideID, !self.isShowing else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let overlayView = OverlayView(recordingSession: recordingSession)
        let hosting = NSHostingController(rootView: overlayView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        if let screenFrame = NSScreen.main?.visibleFrame {
            let target = targetFrame(in: screenFrame)
            panel.setFrame(target, display: false)
        }

        return panel
    }

    private func targetFrame(in screenFrame: CGRect) -> CGRect {
        let width = min(180, screenFrame.width - 80)
        let height: CGFloat = 32
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - height - 28
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func offscreenFrame(in screenFrame: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY + 8
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
