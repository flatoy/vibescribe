import AppKit
import Carbon

enum HotkeyTrigger: Equatable {
    case keyCombo
    case modifierOnly
    case modifierCombo
}

struct Hotkey: Equatable {
    let trigger: HotkeyTrigger
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static let pushToTalkDefault = Hotkey(
        trigger: .modifierOnly,
        keyCode: UInt16(kVK_RightOption),
        modifiers: [.option]
    )

    static let languagePickerDefault = Hotkey(
        trigger: .modifierCombo,
        keyCode: 0,
        modifiers: [.shift, .option]
    )

    var displayName: String {
        switch trigger {
        case .modifierOnly:
            return Hotkey.keyName(for: keyCode)
        case .keyCombo:
            let modifierNames = Hotkey.modifierNames(modifiers)
            let keyName = Hotkey.keyName(for: keyCode)
            if modifierNames.isEmpty {
                return keyName
            }
            return modifierNames.joined(separator: "+") + "+" + keyName
        case .modifierCombo:
            return Hotkey.modifierNames(modifiers).joined(separator: "+")
        }
    }

    private static func modifierNames(_ modifiers: NSEvent.ModifierFlags) -> [String] {
        [
            modifiers.contains(.control) ? "Ctrl" : nil,
            modifiers.contains(.option) ? "Opt" : nil,
            modifiers.contains(.shift) ? "Shift" : nil,
            modifiers.contains(.command) ? "Cmd" : nil,
        ].compactMap { $0 }
    }

    static let comparisonMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    func matchesKeyEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let normalized = event.modifierFlags.intersection(Hotkey.comparisonMask)
        let required = modifiers.intersection(Hotkey.comparisonMask)
        return normalized == required
    }

    func isModifierActive(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let normalized = event.modifierFlags.intersection(Hotkey.comparisonMask)
        let required = modifiers.intersection(Hotkey.comparisonMask)
        return normalized == required
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_RightOption:
            return "Right Option"
        case kVK_Option:
            return "Left Option"
        default:
            return "KeyCode(\(keyCode))"
        }
    }
}

final class HotkeyListener {
    var hotkey: Hotkey
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var modifierComboHeld = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    func start() {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event: event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(event: NSEvent) {
        switch hotkey.trigger {
        case .modifierOnly:
            guard event.type == .flagsChanged else { return }
            guard event.keyCode == hotkey.keyCode else { return }
            if hotkey.isModifierActive(event) {
                onKeyDown?()
            } else {
                onKeyUp?()
            }
        case .keyCombo:
            guard hotkey.matchesKeyEvent(event) else { return }
            switch event.type {
            case .keyDown:
                onKeyDown?()
            case .keyUp:
                onKeyUp?()
            default:
                break
            }
        case .modifierCombo:
            guard event.type == .flagsChanged else { return }
            let normalized = event.modifierFlags.intersection(Hotkey.comparisonMask)
            let required = hotkey.modifiers.intersection(Hotkey.comparisonMask)
            let isHeld = !required.isEmpty && normalized.intersection(required) == required
            guard isHeld != modifierComboHeld else { return }
            modifierComboHeld = isHeld
            if isHeld {
                onKeyDown?()
            } else {
                onKeyUp?()
            }
        }
    }
}
