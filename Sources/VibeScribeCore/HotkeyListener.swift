import AppKit
import Carbon

enum HotkeyTrigger: String, Codable, Equatable, Sendable {
    case keyCombo
    case modifierOnly
    case modifierCombo
}

struct Hotkey: Equatable, Codable, Sendable {
    let trigger: HotkeyTrigger
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(trigger: HotkeyTrigger, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.trigger = trigger
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Hotkey.comparisonMask)
    }

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

    static let escape = Hotkey(trigger: .keyCombo, keyCode: UInt16(kVK_Escape), modifiers: [])

    /// The labels to draw on keycaps, e.g. `["Right ⌥"]` or `["⌥", "⇧"]`.
    var keycaps: [String] {
        switch trigger {
        case .modifierOnly:
            return [Hotkey.keyName(for: keyCode)]
        case .modifierCombo:
            return Hotkey.modifierSymbols(modifiers)
        case .keyCombo:
            return Hotkey.modifierSymbols(modifiers) + [Hotkey.keyName(for: keyCode)]
        }
    }

    var displayName: String {
        switch trigger {
        case .modifierOnly: return keycaps.joined()
        case .modifierCombo, .keyCombo: return keycaps.joined(separator: "")
        }
    }

    static let comparisonMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    func matchesKeyEvent(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let normalized = event.modifierFlags.intersection(Hotkey.comparisonMask)
        return normalized == modifiers
    }

    func isModifierActive(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        if let deviceMask = Hotkey.deviceMask(forKeyCode: keyCode) {
            return event.modifierFlags.rawValue & deviceMask != 0
        }
        return Hotkey.modifierFlag(forKeyCode: keyCode).map { event.modifierFlags.contains($0) } ?? false
    }

    /// Device-dependent bits (IOKit `NX_DEVICE*KEYMASK`) tell the left and right keys apart.
    private static func deviceMask(forKeyCode keyCode: UInt16) -> UInt? {
        switch Int(keyCode) {
        case kVK_Control: return 0x0001
        case kVK_Shift: return 0x0002
        case kVK_RightShift: return 0x0004
        case kVK_Command: return 0x0008
        case kVK_RightCommand: return 0x0010
        case kVK_Option: return 0x0020
        case kVK_RightOption: return 0x0040
        case kVK_RightControl: return 0x2000
        default: return nil
        }
    }

    static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch Int(keyCode) {
        case kVK_Option, kVK_RightOption: return .option
        case kVK_Command, kVK_RightCommand: return .command
        case kVK_Shift, kVK_RightShift: return .shift
        case kVK_Control, kVK_RightControl: return .control
        case kVK_Function: return .function
        default: return nil
        }
    }

    private static func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> [String] {
        [
            modifiers.contains(.control) ? "⌃" : nil,
            modifiers.contains(.option) ? "⌥" : nil,
            modifiers.contains(.shift) ? "⇧" : nil,
            modifiers.contains(.command) ? "⌘" : nil,
        ].compactMap { $0 }
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_RightOption: return "Right ⌥"
        case kVK_Option: return "Left ⌥"
        case kVK_RightCommand: return "Right ⌘"
        case kVK_Command: return "Left ⌘"
        case kVK_RightShift: return "Right ⇧"
        case kVK_Shift: return "Left ⇧"
        case kVK_RightControl: return "Right ⌃"
        case kVK_Control: return "Left ⌃"
        case kVK_Function: return "fn"
        case kVK_Space: return "Space"
        case kVK_Escape: return "esc"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default: return characterName(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    private static func characterName(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case trigger, keyCode, modifiers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            trigger: try container.decode(HotkeyTrigger.self, forKey: .trigger),
            keyCode: try container.decode(UInt16.self, forKey: .keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: try container.decode(UInt.self, forKey: .modifiers))
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
    }
}

extension NSEvent.ModifierFlags: @retroactive @unchecked Sendable {}

final class HotkeyListener {
    var hotkey: Hotkey
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var modifierComboHeld = false
    private var modifierHeld = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    deinit {
        stop()
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
        modifierComboHeld = false
        modifierHeld = false
    }

    private func handle(event: NSEvent) {
        switch hotkey.trigger {
        case .modifierOnly:
            guard event.type == .flagsChanged, event.keyCode == hotkey.keyCode else { return }
            let isHeld = hotkey.isModifierActive(event)
            guard isHeld != modifierHeld else { return }
            modifierHeld = isHeld
            if isHeld {
                onKeyDown?()
            } else {
                onKeyUp?()
            }
        case .keyCombo:
            guard hotkey.matchesKeyEvent(event) else { return }
            switch event.type {
            case .keyDown where !event.isARepeat:
                onKeyDown?()
            case .keyUp:
                onKeyUp?()
            default:
                break
            }
        case .modifierCombo:
            guard event.type == .flagsChanged else { return }
            let normalized = event.modifierFlags.intersection(Hotkey.comparisonMask)
            let required = hotkey.modifiers
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

/// Records the next shortcut typed while a settings field is focused.
@MainActor
final class HotkeyRecorder: ObservableObject {
    enum Target: Equatable {
        case pushToTalk
        case languagePicker
    }

    @Published private(set) var target: Target?

    var onRecord: ((Target, Hotkey) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?

    private var monitor: Any?
    private var pendingModifierKey: UInt16?
    private var peakModifiers: NSEvent.ModifierFlags = []

    func start(_ target: Target) {
        stop()
        self.target = target
        onActiveChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let input = RecordedKey(event)
            let consumed = MainActor.assumeIsolated { self?.handle(input) ?? false }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        pendingModifierKey = nil
        peakModifiers = []
        if target != nil {
            target = nil
            onActiveChanged?(false)
        }
    }

    /// Returns `true` when the key press was used for recording.
    private func handle(_ key: RecordedKey) -> Bool {
        guard let target else { return false }
        let modifiers = key.modifiers.intersection(Hotkey.comparisonMask)

        if key.isKeyDown {
            if key.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                stop()
                return true
            }
            // Push-to-talk without modifiers would type into other apps, so require one.
            guard !modifiers.isEmpty || target == .languagePicker || Hotkey.isFunctionKey(key.keyCode) else {
                NSSound.beep()
                return true
            }
            finish(Hotkey(trigger: .keyCombo, keyCode: key.keyCode, modifiers: modifiers))
            return true
        }

        // flagsChanged: a modifier went down or up.
        if key.isModifierPress {
            peakModifiers.formUnion(modifiers)
            pendingModifierKey = peakModifiers.subtracting(modifiers).isEmpty && modifiers.count == 1
                ? key.keyCode : nil
            return true
        }
        // Released: when nothing else is held, record what was pressed.
        guard modifiers.isEmpty else { return true }
        defer { peakModifiers = [] }
        if peakModifiers.count >= 2 {
            finish(Hotkey(trigger: .modifierCombo, keyCode: 0, modifiers: peakModifiers))
        } else if let key = pendingModifierKey, target == .pushToTalk {
            finish(Hotkey(trigger: .modifierOnly, keyCode: key, modifiers: peakModifiers))
        }
        return true
    }

    private func finish(_ hotkey: Hotkey) {
        guard let target else { return }
        stop()
        onRecord?(target, hotkey)
    }
}

/// The parts of a key event the recorder needs, copied so they can cross isolation.
private struct RecordedKey: Sendable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let isKeyDown: Bool
    let isModifierPress: Bool

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        modifiers = event.modifierFlags
        isKeyDown = event.type == .keyDown
        isModifierPress = event.type == .flagsChanged
            && Hotkey(trigger: .modifierOnly, keyCode: event.keyCode, modifiers: []).isModifierActive(event)
    }
}

extension NSEvent.ModifierFlags {
    var count: Int {
        [NSEvent.ModifierFlags.control, .option, .shift, .command].filter { contains($0) }.count
    }
}

extension Hotkey {
    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        let functionKeys: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
        ]
        return functionKeys.contains(Int(keyCode))
    }
}
