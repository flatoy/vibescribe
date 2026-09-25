import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID

    var id: String { uid }
}

/// Core Audio lookups for microphones.
enum AudioInputDevices {
    static func all() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap(device(for:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
        else { return nil }
        return device(for: deviceID)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        all().first { $0.uid == uid }?.deviceID
    }

    static func select(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) {
        guard let unit = inputNode.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private static func device(for id: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0,
              let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: id),
              let name = stringProperty(kAudioObjectPropertyName, of: id) else { return nil }
        return AudioInputDevice(uid: uid, name: name, deviceID: id)
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}

/// Lists microphones and runs a level meter while the settings page is open.
@MainActor
final class MicrophoneMonitor: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var defaultDevice: AudioInputDevice?
    let level = LevelMeter()

    private var engine: AVAudioEngine?
    private var listener: AudioObjectPropertyListenerBlock?
    private var monitoredUID: String??

    init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    func refresh() {
        devices = AudioInputDevices.all()
        defaultDevice = AudioInputDevices.defaultDevice()
    }

    /// Starts metering the given microphone. Only runs when microphone access is granted.
    func startMetering(uid: String?) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        if engine != nil, monitoredUID == .some(uid) { return }
        stopMetering()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid, let id = AudioInputDevices.deviceID(forUID: uid) {
            AudioInputDevices.select(id, on: input)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapHandler(level: level))
        do {
            try engine.start()
            self.engine = engine
            monitoredUID = .some(uid)
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    /// Built outside the main actor: the tap runs on a real-time audio thread.
    private nonisolated static func tapHandler(level: LevelMeter) -> AVAudioNodeTapBlock {
        { buffer, _ in
            let value = LevelMeter.normalizedLevel(of: buffer)
            Task { @MainActor in level.push(value) }
        }
    }

    func stopMetering() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        monitoredUID = nil
        level.reset()
    }
}
