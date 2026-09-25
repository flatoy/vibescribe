import AppKit
import SwiftUI

/// A transparent area that drags the app bundle as a file URL, which is what the
/// privacy lists in System Settings accept. Starts on the first click, even in an inactive panel.
struct AppDragSource: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> DragView {
        DragView(url: url)
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.url = url
    }

    final class DragView: NSView, NSDraggingSource {
        var url: URL
        private var mouseDownEvent: NSEvent?

        init(url: URL) {
            self.url = url
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent else { return }
            let distance = hypot(event.locationInWindow.x - start.locationInWindow.x,
                                 event.locationInWindow.y - start.locationInWindow.y)
            guard distance > 3 else { return }
            mouseDownEvent = nil

            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let size = NSSize(width: 48, height: 48)
            let point = convert(start.locationInWindow, from: nil)
            item.setDraggingFrame(
                NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                contents: icon
            )
            beginDraggingSession(with: [item], event: start, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
