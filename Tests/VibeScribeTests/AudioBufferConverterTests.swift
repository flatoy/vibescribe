import AVFoundation
@testable import VibeScribeCore

@MainActor
func runAudioBufferConverterTests(_ t: TestHarness) {
    t.run("linear16Data converts float samples") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        let channel = buffer.floatChannelData![0]
        channel[0] = -1.0
        channel[1] = 0.0
        channel[2] = 1.0

        let data = try t.require(AudioBufferConverter.linear16Data(from: buffer))
        let values = data.withUnsafeBytes { ptr -> [Int16] in
            Array(ptr.bindMemory(to: Int16.self))
        }
        t.expectEqual(values, [-32767, 0, 32767])
    }

    t.run("linear16Data clamps out-of-range samples") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let channel = buffer.floatChannelData![0]
        channel[0] = 2.0
        channel[1] = -2.0

        let data = try t.require(AudioBufferConverter.linear16Data(from: buffer))
        let values = data.withUnsafeBytes { ptr -> [Int16] in
            Array(ptr.bindMemory(to: Int16.self))
        }
        t.expectEqual(values, [32767, -32767])
    }
}
