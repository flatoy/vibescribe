import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct AudioStreamFormat {
    let sampleRate: Int
    let channels: Int
}

final class AudioCaptureController: NSObject {
    private var engine = AVAudioEngine()
    private var isRunning = false

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

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngine()
            resetEngine()
            throw error
        }
        isRunning = true

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

    @objc private func handleConfigurationChangeNotification(_ notification: Notification) {
        handleConfigurationChange()
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        stopEngine()
        resetEngine()
        onConfigurationChanged?()
    }
}
