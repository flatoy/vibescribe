import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct AudioStreamFormat {
    let sampleRate: Int
    let channels: Int
}

enum AudioCaptureError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone is available."
        }
    }
}

final class AudioCaptureController: NSObject {
    /// What to do when the engine reports a configuration change.
    enum ConfigurationChangeAction: Equatable {
        case ignore
        /// Start the same engine again. Building a new one would select the microphone again, and
        /// selecting a microphone can itself post a configuration change.
        case restartInPlace
        /// Build a new engine for the new format, then let the owner start it.
        case rebuild
    }

    static let maxInPlaceRestarts = 3

    private var engine = AVAudioEngine()
    private var isRunning = false
    private var tapFormat: AVAudioFormat?
    private var hardwareFormat: AVAudioFormat?
    private var inPlaceRestarts = 0

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onConfigurationChanged: (() -> Void)?
    /// Core Audio UID of the microphone to use. `nil` follows the system default.
    var inputDeviceUID: String?

    override init() {
        super.init()
        installConfigurationObserver()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() throws -> AudioStreamFormat {
        guard !isRunning else {
            if let format = currentFormat() {
                return format
            }
            return AudioStreamFormat(sampleRate: 16000, channels: 1)
        }

        resetEngine()
        let inputNode = engine.inputNode
        if let uid = inputDeviceUID, let deviceID = AudioInputDevices.deviceID(forUID: uid) {
            AudioInputDevices.select(deviceID, on: inputNode)
        }
        let format = inputNode.outputFormat(forBus: 0)
        // installTap raises an exception for an empty format, which is what an unplugged microphone reports.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInput }

        installTap(on: inputNode, format: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngine()
            resetEngine()
            throw error
        }
        isRunning = true
        tapFormat = format
        hardwareFormat = inputNode.inputFormat(forBus: 0)
        inPlaceRestarts = 0

        return AudioStreamFormat(sampleRate: Int(format.sampleRate), channels: Int(format.channelCount))
    }

    func stop() {
        guard isRunning else { return }
        stopEngine()
    }

    private func currentFormat() -> AudioStreamFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return nil }
        return AudioStreamFormat(sampleRate: Int(format.sampleRate), channels: Int(format.channelCount))
    }

    private func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func resetEngine() {
        removeConfigurationObserver()
        engine = AVAudioEngine()
        installConfigurationObserver()
    }

    private func installConfigurationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChangeNotification(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    private func removeConfigurationObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    /// Posted on an internal AVAudioEngine queue, where tearing the engine down can deadlock,
    /// so the work moves to the main thread like every other start and stop.
    @objc private func handleConfigurationChangeNotification(_ notification: Notification) {
        performSelector(
            onMainThread: #selector(handleConfigurationChange(from:)),
            with: notification.object,
            waitUntilDone: false
        )
    }

    /// The engine has stopped itself. Bluetooth headsets get here right after `start()`, when
    /// opening their microphone switches them to a lower-quality headset profile.
    @objc private func handleConfigurationChange(from source: AnyObject?) {
        // Ignore a late notice from an engine that `start()` has since replaced.
        guard isRunning, source === engine, let tapFormat, let hardwareFormat else { return }
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        let action = Self.action(
            engineRunning: engine.isRunning,
            formatUnchanged: hardware.sampleRate == hardwareFormat.sampleRate
                && hardware.channelCount == hardwareFormat.channelCount,
            inPlaceRestarts: inPlaceRestarts
        )
        switch action {
        case .ignore:
            return
        case .restartInPlace:
            inPlaceRestarts += 1
            if restartInPlace(format: tapFormat) { return }
        case .rebuild:
            break
        }
        stopEngine()
        resetEngine()
        onConfigurationChanged?()
    }

    private func restartInPlace(format: AVAudioFormat) -> Bool {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        installTap(on: inputNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    /// A notice that arrives while the engine still runs in the tap's format came from `start()`
    /// itself, before the engine started.
    static func action(engineRunning: Bool, formatUnchanged: Bool, inPlaceRestarts: Int) -> ConfigurationChangeAction {
        guard formatUnchanged else { return .rebuild }
        if engineRunning { return .ignore }
        return inPlaceRestarts < maxInPlaceRestarts ? .restartInPlace : .rebuild
    }
}
