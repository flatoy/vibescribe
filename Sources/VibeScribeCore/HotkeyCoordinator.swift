import Foundation

public enum HotkeyIntent: Equatable, Sendable {
    case startRecording
    /// The recording keeps going without holding the key.
    case handsFree
    case stopRecording
    case cancelRecording
    case openLanguagePicker
}

public enum HotkeyTriggerMode: Sendable {
    /// Hold to talk, or tap to start and tap again to stop.
    case holdOrTap
    /// Recording lasts only while the key is held.
    case holdOnly
    /// Each press toggles recording.
    case tapOnly
}

@MainActor
public protocol HotkeyScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any HotkeyCancellable
}

public protocol HotkeyCancellable: AnyObject, Sendable {
    func cancel()
}

@MainActor
public final class HotkeyCoordinator {
    public var onIntent: ((HotkeyIntent) -> Void)?
    public var mode: HotkeyTriggerMode = .holdOrTap {
        didSet { if mode != oldValue { reset() } }
    }

    public let comboDebounce: TimeInterval
    public let tapThreshold: TimeInterval
    public let stopDelay: TimeInterval

    private let scheduler: any HotkeyScheduler

    private var recording = false
    private var latched = false
    /// Set while the picker combo is held: its keys overlap the dictation key, and the
    /// two listeners see the same key event in either order.
    private var comboHeld = false
    private var pressedAt: TimeInterval?
    private var pendingStart: (any HotkeyCancellable)?
    private var pendingStop: (any HotkeyCancellable)?

    public init(
        scheduler: any HotkeyScheduler,
        comboDebounce: TimeInterval = 0.05,
        tapThreshold: TimeInterval = 0.25,
        stopDelay: TimeInterval = 0.2
    ) {
        self.scheduler = scheduler
        self.comboDebounce = comboDebounce
        self.tapThreshold = tapThreshold
        self.stopDelay = stopDelay
    }

    public func primaryDown(at now: TimeInterval) {
        guard !comboHeld else { return }
        if mode == .tapOnly {
            tapOnlyDown()
            return
        }
        pendingStop?.cancel()
        pendingStop = nil
        pressedAt = now

        if recording { return }
        if pendingStart != nil { return }
        pendingStart = scheduler.schedule(after: comboDebounce) { [weak self] in
            self?.commitStart()
        }
    }

    public func primaryUp(at now: TimeInterval) {
        guard !comboHeld else { return }
        guard mode != .tapOnly else { return }
        guard let pressedAt else { return }
        let duration = now - pressedAt
        self.pressedAt = nil
        let isTap = duration <= tapThreshold && mode == .holdOrTap

        if mode == .holdOnly, let pending = pendingStart {
            // Released before recording began: too short to be speech.
            pending.cancel()
            pendingStart = nil
            return
        }

        if let pending = pendingStart {
            pending.cancel()
            pendingStart = nil
            if isTap {
                commitStart()
                latched = true
                pendingStop?.cancel()
                pendingStop = nil
                onIntent?(.handsFree)
            }
            return
        }

        if isTap {
            if latched {
                latched = false
                pendingStop?.cancel()
                pendingStop = scheduler.schedule(after: stopDelay) { [weak self] in
                    self?.commitStop()
                }
            } else {
                latched = true
                pendingStop?.cancel()
                pendingStop = nil
                onIntent?(.handsFree)
            }
            return
        }

        if latched { return }
        pendingStop?.cancel()
        pendingStop = scheduler.schedule(after: stopDelay) { [weak self] in
            self?.commitStop()
        }
    }

    public func comboTriggered() {
        comboHeld = true
        pendingStart?.cancel()
        pendingStart = nil
        pendingStop?.cancel()
        pendingStop = nil
        pressedAt = nil

        if recording {
            recording = false
            latched = false
            onIntent?(.cancelRecording)
        }
        onIntent?(.openLanguagePicker)
    }

    public func comboReleased() {
        comboHeld = false
        pressedAt = nil
    }

    /// Escape while recording throws the audio away.
    public func cancelRequested() {
        guard recording || pendingStart != nil else { return }
        let wasRecording = recording
        reset()
        if wasRecording {
            onIntent?(.cancelRecording)
        }
    }

    public var isRecording: Bool { recording }

    public func reset() {
        pendingStart?.cancel()
        pendingStart = nil
        pendingStop?.cancel()
        pendingStop = nil
        pressedAt = nil
        recording = false
        latched = false
        comboHeld = false
    }

    private func tapOnlyDown() {
        if recording {
            guard pendingStop == nil else { return }
            pendingStop = scheduler.schedule(after: 0) { [weak self] in
                self?.commitStop()
            }
            return
        }
        guard pendingStart == nil else { return }
        pendingStart = scheduler.schedule(after: comboDebounce) { [weak self] in
            guard let self else { return }
            self.commitStart()
            self.onIntent?(.handsFree)
        }
    }

    private func commitStart() {
        pendingStart = nil
        recording = true
        onIntent?(.startRecording)
    }

    private func commitStop() {
        pendingStop = nil
        recording = false
        onIntent?(.stopRecording)
    }
}

@MainActor
public final class DispatchHotkeyScheduler: HotkeyScheduler {
    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any HotkeyCancellable {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { work() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return DispatchHotkeyCancellable(item: item)
    }
}

private final class DispatchHotkeyCancellable: HotkeyCancellable, @unchecked Sendable {
    private let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

@MainActor
public final class ManualHotkeyScheduler: HotkeyScheduler {
    private struct Item {
        let due: TimeInterval
        let work: @MainActor () -> Void
        let cancellable: ManualHotkeyCancellable
    }

    private var scheduled: [Item] = []
    public private(set) var now: TimeInterval = 0

    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any HotkeyCancellable {
        let cancellable = ManualHotkeyCancellable()
        scheduled.append(Item(due: now + delay, work: work, cancellable: cancellable))
        return cancellable
    }

    public func advance(to time: TimeInterval) {
        now = time
        let ready = scheduled.filter { !$0.cancellable.canceled && $0.due <= now }
        scheduled.removeAll { $0.cancellable.canceled || $0.due <= now }
        for item in ready {
            item.work()
        }
    }

    public func advance(by interval: TimeInterval) {
        advance(to: now + interval)
    }
}

public final class ManualHotkeyCancellable: HotkeyCancellable, @unchecked Sendable {
    public var canceled = false
    public init() {}
    public func cancel() { canceled = true }
}
