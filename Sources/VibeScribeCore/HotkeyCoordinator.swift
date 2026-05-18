import Foundation

public enum HotkeyIntent: Equatable, Sendable {
    case startRecording
    case stopRecording
    case cancelRecording
    case openLanguagePicker
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

    public let comboDebounce: TimeInterval
    public let tapThreshold: TimeInterval
    public let stopDelay: TimeInterval

    private let scheduler: any HotkeyScheduler

    private var recording = false
    private var latched = false
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
        guard let pressedAt else { return }
        let duration = now - pressedAt
        self.pressedAt = nil
        let isTap = duration <= tapThreshold

        if let pending = pendingStart {
            pending.cancel()
            pendingStart = nil
            if isTap {
                commitStart()
                latched = true
                pendingStop?.cancel()
                pendingStop = nil
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
