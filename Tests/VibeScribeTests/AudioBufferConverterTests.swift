import AVFoundation
import Foundation
@testable import VibeScribeCore

@MainActor
func runAudioBufferConverterTests(_ t: TestHarness) {
    t.run("downmixes stereo microphone buffers to mono") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
        buffer.frameLength = 3
        let channels = buffer.floatChannelData!
        channels[0][0] = 1
        channels[0][1] = 0
        channels[0][2] = -1
        channels[1][0] = 0
        channels[1][1] = 1
        channels[1][2] = 0

        let samples = try t.require(AudioBufferConverter.monoSamples(from: buffer))
        t.expectEqual(samples, [0.5, 0.5, -0.5])
    }

    t.run("downmixes interleaved stereo buffers") {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)!
        buffer.frameLength = 2
        let data = buffer.floatChannelData![0]
        data[0] = 1
        data[1] = 0
        data[2] = 0
        data[3] = -1

        let samples = try t.require(AudioBufferConverter.monoSamples(from: buffer))
        t.expectEqual(samples, [0.5, -0.5])
    }

    t.run("resamples a 48 kHz signal to WhisperKit's 16 kHz input") {
        let input = (0..<48_000).map { frame in
            Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000))
        }
        let output = try AudioBufferConverter.whisperSamples(from: input, sampleRate: 48_000)
        t.expect(abs(output.count - 16_000) <= 2, "Expected about 16,000 samples, got \(output.count)")
        t.expect(output.contains { abs($0) > 0.5 }, "Expected an audible signal after resampling")
    }

    t.run("keeps already normalized audio unchanged") {
        let input: [Float] = [0.25, -0.5, 0.75]
        let output = try AudioBufferConverter.whisperSamples(from: input, sampleRate: 16_000)
        t.expectEqual(output, input)
    }
}
