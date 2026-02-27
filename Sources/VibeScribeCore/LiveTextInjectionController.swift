import ApplicationServices
import Carbon
import Foundation

@MainActor
final class LiveTextInjectionController {
    enum AppendDecision: Equatable {
        case append(String)
        case rebase
    }

    private struct FocusAnchor {
        let appPID: pid_t
    }

    private let updateInterval: TimeInterval
    private let onLog: ((String, LogLevel) -> Void)?

    private var focusAnchor: FocusAnchor?
    private var scheduledUpdate: DispatchWorkItem?
    private var lastUpdateAt: Date = .distantPast
    private var requestedText = ""
    private var typedText = ""
    private var hasLoggedNonAppendMismatch = false

    private(set) var isSessionActive = false
    private(set) var isFrozen = false

    init(
        updateInterval: TimeInterval = 0.12,
        onLog: ((String, LogLevel) -> Void)? = nil
    ) {
        self.updateInterval = updateInterval
        self.onLog = onLog
    }

    func startSession() -> Bool {
        endSession()

        guard AXIsProcessTrusted() else {
            onLog?("Accessibility permission not granted. Live insertion disabled.", .warning)
            return false
        }

        guard let focusAnchor = captureFocusAnchor() else {
            onLog?("No focused app found. Live insertion disabled.", .warning)
            return false
        }

        self.focusAnchor = focusAnchor
        requestedText = ""
        typedText = ""
        hasLoggedNonAppendMismatch = false
        lastUpdateAt = .distantPast
        isSessionActive = true
        isFrozen = false
        onLog?("Live insertion enabled (append-only).", .info)
        return true
    }

    func enqueueAppend(to fullText: String) {
        guard isSessionActive, !isFrozen else { return }

        requestedText = fullText
        scheduleUpdate()
    }

    func flush() {
        scheduledUpdate?.cancel()
        scheduledUpdate = nil
        applyUpdateIfNeeded()
    }

    func fallbackText(for finalText: String) -> String {
        Self.fallbackText(finalText: finalText, injectedText: typedText)
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

        return ""
    }

    func endSession() {
        scheduledUpdate?.cancel()
        scheduledUpdate = nil

        focusAnchor = nil
        requestedText = ""
        typedText = ""
        hasLoggedNonAppendMismatch = false
        lastUpdateAt = .distantPast
        isSessionActive = false
        isFrozen = false
    }

    private func scheduleUpdate() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdateAt)

        if elapsed >= updateInterval {
            scheduledUpdate?.cancel()
            scheduledUpdate = nil
            applyUpdateIfNeeded()
            return
        }

        guard scheduledUpdate == nil else { return }
        let delay = max(0, updateInterval - elapsed)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledUpdate = nil
                self.applyUpdateIfNeeded()
            }
        }
        scheduledUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyUpdateIfNeeded() {
        guard isSessionActive, !isFrozen else { return }
        guard requestedText != typedText else { return }

        guard isFocusedTargetUnchanged() else {
            freeze(reason: "Focused app changed. Live insertion is paused; transcript will still finalize.")
            return
        }

        switch Self.appendDecision(from: typedText, to: requestedText) {
        case .append(let appendSuffix):
            guard appendSuffix.isEmpty || typeText(appendSuffix) else {
                freeze(reason: "Failed to insert live text into focused app. Live insertion is paused.")
                return
            }
            typedText += appendSuffix
            hasLoggedNonAppendMismatch = false
            lastUpdateAt = Date()
        case .rebase:
            if let salvageSuffix = Self.salvageAppendSuffix(from: typedText, to: requestedText) {
                guard salvageSuffix.isEmpty || typeText(salvageSuffix) else {
                    freeze(reason: "Failed to insert live text into focused app. Live insertion is paused.")
                    return
                }
                typedText += salvageSuffix
                hasLoggedNonAppendMismatch = false
                lastUpdateAt = Date()
                return
            }

            if !hasLoggedNonAppendMismatch {
                onLog?("Skipped in-place correction to avoid destructive edits; continuing append-only live typing.", .warning)
                hasLoggedNonAppendMismatch = true
            }
            lastUpdateAt = Date()
        }
    }

    private func isFocusedTargetUnchanged() -> Bool {
        guard let focusAnchor else { return false }
        guard let current = captureFocusAnchor() else { return false }
        return focusAnchor.appPID == current.appPID
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
        return FocusAnchor(appPID: appPID)
    }

    private func typeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        // Emit one character at a time with no modifier flags. This avoids
        // app-dependent behavior when the push-to-talk modifier key is held.
        for character in text {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(0), keyDown: false)
            guard keyDown != nil, keyUp != nil else { return false }

            keyDown?.flags = []
            keyUp?.flags = []

            let unicodeScalars: [UniChar] = Array(String(character).utf16)
            keyDown?.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)
            keyUp?.keyboardSetUnicodeString(stringLength: unicodeScalars.count, unicodeString: unicodeScalars)

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
        return true
    }

    private func freeze(reason: String) {
        guard isSessionActive, !isFrozen else { return }
        scheduledUpdate?.cancel()
        scheduledUpdate = nil
        isFrozen = true
        onLog?(reason, .warning)
    }

    static func appendOnlySuffix(from previousText: String, to targetText: String) -> String? {
        guard targetText.hasPrefix(previousText) else { return nil }
        let start = targetText.index(targetText.startIndex, offsetBy: previousText.count)
        return String(targetText[start...])
    }

    static func appendDecision(from previousText: String, to targetText: String) -> AppendDecision {
        guard let suffix = appendOnlySuffix(from: previousText, to: targetText) else {
            return .rebase
        }
        return .append(suffix)
    }

    static func salvageAppendSuffix(from previousText: String, to targetText: String) -> String? {
        guard !previousText.isEmpty else { return targetText }
        guard !targetText.isEmpty else { return nil }

        var previousIndex = previousText.startIndex
        var targetIndex = targetText.startIndex

        while previousIndex < previousText.endIndex, targetIndex < targetText.endIndex {
            let previousChar = Self.normalizedChar(previousText[previousIndex])
            if previousChar == nil {
                previousIndex = previousText.index(after: previousIndex)
                continue
            }

            let targetChar = Self.normalizedChar(targetText[targetIndex])
            if targetChar == nil {
                targetIndex = targetText.index(after: targetIndex)
                continue
            }

            if previousChar == targetChar {
                previousIndex = previousText.index(after: previousIndex)
                targetIndex = targetText.index(after: targetIndex)
            } else {
                targetIndex = targetText.index(after: targetIndex)
            }
        }

        guard previousIndex == previousText.endIndex else { return nil }
        return String(targetText[targetIndex...])
    }

    private static func normalizedChar(_ character: Character) -> Character? {
        let lower = String(character).lowercased()
        guard let scalar = lower.unicodeScalars.first else { return nil }
        if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
            return Character(lower)
        }
        return nil
    }
}
