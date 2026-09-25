import AppKit
import ApplicationServices
import Carbon

enum OutputResult: Equatable {
    case pasted
    case copied
}

/// Puts a transcript into the active app, or on the clipboard.
@MainActor
final class TextOutput {
    private let preferences: Preferences
    private let logger: Logger
    private let clipboardRestoreDelay: TimeInterval = 0.25

    init(preferences: Preferences, logger: Logger) {
        self.preferences = preferences
        self.logger = logger
    }

    @discardableResult
    func deliver(_ text: String) -> OutputResult {
        let pasteboard = NSPasteboard.general
        let canPaste = preferences.outputMode == .paste && AXIsProcessTrusted()
        guard canPaste else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if preferences.outputMode == .paste {
                logger.append("Paste skipped: Accessibility not granted. Copied instead.", level: .warning)
            } else {
                logger.append("Transcript copied to the clipboard.", level: .info)
            }
            return .copied
        }

        let snapshot = preferences.restoreClipboard ? PasteboardSnapshot(pasteboard: pasteboard) : nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.append("Could not create a keyboard event to paste. The transcript is on the clipboard.", level: .error)
            return .copied
        }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        logger.append("Pasted into the active app.", level: .info)

        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                snapshot.restore(to: pasteboard)
            }
        }
        return .pasted
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
