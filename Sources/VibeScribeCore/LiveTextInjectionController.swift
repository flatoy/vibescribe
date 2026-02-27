import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
final class LiveTextInjectionController {
    enum RewriteStyle {
        case replaceInPlace
        case appendDuringInterim
    }

    struct RewriteOperation: Equatable {
        let deleteCount: Int
        let insertSuffix: String
    }

    private struct FocusAnchor {
        let appPID: pid_t
        let selectionStart: Int?
    }

    private let updateInterval: TimeInterval
    private let onLog: ((String, LogLevel) -> Void)?

    private var focusAnchor: FocusAnchor?
    private var pasteboardSnapshot: PasteboardSnapshot?
    private var scheduledRewrite: DispatchWorkItem?
    private var lastRewriteAt: Date = .distantPast
    private var requestedText = ""
    private var requestedIsFinal = false
    private var injectedText = ""
    private var rewriteStyle: RewriteStyle = .replaceInPlace

    private(set) var isSessionActive = false
    private(set) var isFrozen = false

    init(
        updateInterval: TimeInterval = 0.12,
        onLog: ((String, LogLevel) -> Void)? = nil
    ) {
        self.updateInterval = updateInterval
        self.onLog = onLog
    }

    func startSession(rewriteStyle: RewriteStyle = .replaceInPlace) -> Bool {
        endSession()

        guard AXIsProcessTrusted() else {
            onLog?("Accessibility permission not granted. Live insertion disabled.", .warning)
            return false
        }

        guard let focusAnchor = captureFocusAnchor() else {
            onLog?("No focused text input found. Live insertion disabled.", .warning)
            return false
        }

        self.focusAnchor = focusAnchor
        pasteboardSnapshot = PasteboardSnapshot(pasteboard: .general)
        requestedText = ""
        requestedIsFinal = false
        injectedText = ""
        lastRewriteAt = .distantPast
        self.rewriteStyle = rewriteStyle
        isSessionActive = true
        isFrozen = false
        onLog?("Live insertion enabled.", .info)
        return true
    }

    func enqueueRewrite(to fullText: String, isFinal: Bool) {
        guard isSessionActive, !isFrozen else { return }

        requestedText = fullText
        requestedIsFinal = isFinal
        scheduleRewrite()
    }

    func flush() {
        scheduledRewrite?.cancel()
        scheduledRewrite = nil
        applyRewriteIfNeeded()
    }

    func fallbackText(for finalText: String) -> String {
        Self.fallbackText(finalText: finalText, injectedText: injectedText)
    }

    static func fallbackText(finalText: String, injectedText: String) -> String {
        let trimmedFinal = finalText.trimmed
        guard !trimmedFinal.isEmpty else { return "" }
        let trimmedInjected = injectedText.trimmed
        guard !trimmedInjected.isEmpty else { return trimmedFinal }

        if trimmedFinal.hasPrefix(trimmedInjected) {
            let suffixStart = trimmedFinal.index(trimmedFinal.startIndex, offsetBy: trimmedInjected.count)
            return String(trimmedFinal[suffixStart...])
        }

        return trimmedFinal
    }

    func endSession() {
        scheduledRewrite?.cancel()
        scheduledRewrite = nil

        if let pasteboardSnapshot {
            pasteboardSnapshot.restore(to: .general)
        }

        focusAnchor = nil
        pasteboardSnapshot = nil
        requestedText = ""
        requestedIsFinal = false
        injectedText = ""
        lastRewriteAt = .distantPast
        rewriteStyle = .replaceInPlace
        isSessionActive = false
        isFrozen = false
    }

    private func scheduleRewrite() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRewriteAt)

        if elapsed >= updateInterval {
            scheduledRewrite?.cancel()
            scheduledRewrite = nil
            applyRewriteIfNeeded()
            return
        }

        guard scheduledRewrite == nil else { return }
        let delay = max(0, updateInterval - elapsed)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledRewrite = nil
                self.applyRewriteIfNeeded()
            }
        }
        scheduledRewrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyRewriteIfNeeded() {
        guard isSessionActive, !isFrozen else { return }
        guard requestedText != injectedText else { return }

        guard isFocusedTargetUnchanged() else {
            freeze(reason: "Focus or cursor changed. Live insertion is paused; transcript will still finalize.")
            return
        }

        let target = requestedText
        let rewrite = Self.rewriteOperation(from: injectedText, to: target)

        let shouldDelete = rewrite.deleteCount > 0 && Self.allowsDelete(
            rewriteStyle: rewriteStyle,
            isFinal: requestedIsFinal
        )

        if rewrite.deleteCount > 0, !shouldDelete {
            return
        }

        if shouldDelete, !sendBackspace(count: rewrite.deleteCount) {
            freeze(reason: "Failed to send backspace events. Live insertion is paused.")
            return
        }

        if !rewrite.insertSuffix.isEmpty, !pasteText(rewrite.insertSuffix) {
            freeze(reason: "Failed to insert live text into focused app. Live insertion is paused.")
            return
        }

        injectedText = target
        lastRewriteAt = Date()
    }

    private func isFocusedTargetUnchanged() -> Bool {
        guard let focusAnchor else { return false }
        guard let current = captureFocusAnchor() else { return false }
        guard focusAnchor.appPID == current.appPID else { return false }

        if
            let anchorSelection = focusAnchor.selectionStart,
            let currentSelection = current.selectionStart
        {
            let expectedSelection = anchorSelection + injectedText.count
            guard abs(currentSelection - expectedSelection) <= 2 else { return false }
        }

        return true
    }

    private func captureFocusAnchor() -> FocusAnchor? {
        let systemElement = AXUIElementCreateSystemWide()

        var focusedAppValue: CFTypeRef?
        let focusedAppResult = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        )
        guard focusedAppResult == .success, let focusedAppValue else {
            return nil
        }
        guard CFGetTypeID(focusedAppValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedApp = unsafeDowncast(focusedAppValue, to: AXUIElement.self)

        var appPID: pid_t = 0
        AXUIElementGetPid(focusedApp, &appPID)

        var focusedElementValue: CFTypeRef?
        let focusedElementResult = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementResult == .success, let focusedElementValue else {
            return FocusAnchor(
                appPID: appPID,
                selectionStart: nil
            )
        }
        guard CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return FocusAnchor(
                appPID: appPID,
                selectionStart: nil
            )
        }
        let focusedElement = unsafeDowncast(focusedElementValue, to: AXUIElement.self)

        return FocusAnchor(
            appPID: appPID,
            selectionStart: selectedTextRangeLocation(in: focusedElement)
        )
    }

    private func selectedTextRangeLocation(in element: AXUIElement) -> Int? {
        var selectedRangeValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        guard result == .success, let selectedRangeValue else {
            return nil
        }
        guard CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(selectedRangeValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.length == 0 else {
            return nil
        }
        return range.location
    }

    private func sendBackspace(count: Int) -> Bool {
        guard count > 0 else { return true }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        for _ in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)
            guard keyDown != nil, keyUp != nil else { return false }
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }

        return true
    }

    private func pasteText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        guard keyDown != nil, keyUp != nil else { return false }
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        return true
    }

    private func freeze(reason: String) {
        guard isSessionActive, !isFrozen else { return }
        scheduledRewrite?.cancel()
        scheduledRewrite = nil
        isFrozen = true
        onLog?(reason, .warning)
    }

    static func rewriteOperation(from previousText: String, to targetText: String) -> RewriteOperation {
        let commonPrefixCount = commonPrefixCharacterCount(between: previousText, and: targetText)
        let deleteCount = previousText.count - commonPrefixCount
        let insertStart = targetText.index(targetText.startIndex, offsetBy: commonPrefixCount)
        let insertSuffix = String(targetText[insertStart...])
        return RewriteOperation(deleteCount: deleteCount, insertSuffix: insertSuffix)
    }

    static func allowsDelete(rewriteStyle: RewriteStyle, isFinal: Bool) -> Bool {
        switch rewriteStyle {
        case .replaceInPlace:
            return true
        case .appendDuringInterim:
            return isFinal
        }
    }

    private static func commonPrefixCharacterCount(between lhs: String, and rhs: String) -> Int {
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        var count = 0

        while lhsIndex < lhs.endIndex, rhsIndex < rhs.endIndex, lhs[lhsIndex] == rhs[rhsIndex] {
            count += 1
            lhsIndex = lhs.index(after: lhsIndex)
            rhsIndex = rhs.index(after: rhsIndex)
        }

        return count
    }
}
