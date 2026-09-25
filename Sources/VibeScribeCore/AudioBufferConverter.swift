import AVFoundation
import WhisperKit

enum AudioBufferConverter {
    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0 else { return nil }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        var samples = [Float](repeating: 0, count: frameLength)
        for frame in 0..<frameLength {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let index = buffer.format.isInterleaved ? frame * channelCount + channel : frame
                let channelIndex = buffer.format.isInterleaved ? 0 : channel
                sum += channelData[channelIndex][index]
            }
            samples[frame] = sum / Float(channelCount)
        }
        return samples
    }

    static func whisperSamples(from samples: [Float], sampleRate: Double) throws -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw WhisperError.audioProcessingFailed("Invalid microphone sample rate")
        }
        guard !samples.isEmpty else { return [] }
        if sampleRate == Double(WhisperKit.sampleRate) { return samples }
        guard samples.count <= Int(AVAudioFrameCount.max),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let inputData = input.floatChannelData else {
            throw WhisperError.audioProcessingFailed("Failed to prepare microphone audio")
        }
        samples.withUnsafeBufferPointer { source in
            inputData[0].update(from: source.baseAddress!, count: samples.count)
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        guard let output = AudioProcessor.resampleAudio(
            fromBuffer: input,
            toSampleRate: Double(WhisperKit.sampleRate),
            channelCount: 1
        ), let outputData = output.floatChannelData else {
            throw WhisperError.audioProcessingFailed("Failed to convert microphone audio to 16 kHz")
        }
        return Array(UnsafeBufferPointer(start: outputData[0], count: Int(output.frameLength)))
    }
}
