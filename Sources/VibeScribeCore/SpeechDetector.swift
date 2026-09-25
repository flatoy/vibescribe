import Foundation

/// Decides whether a recording contains speech before it reaches the model.
/// Whisper tends to invent phrases like "Thank you." when given silence.
enum SpeechDetector {
    /// Loudness above the room's noise floor that counts as voice.
    static let marginAboveNoise: Float = 12
    /// Anything quieter than this is never speech, however quiet the room.
    static let absoluteFloor: Float = -50
    /// Voiced audio needed, in seconds. Longer than a key click.
    static let minimumVoicedSeconds: Double = 0.24

    static func containsSpeech(_ samples: [Float], sampleRate: Double) -> Bool {
        let windowSize = max(Int(sampleRate * 0.03), 1)
        guard samples.count >= windowSize else { return false }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / windowSize)
        var start = 0
        while start + windowSize <= samples.count {
            var sum: Float = 0
            for index in start..<(start + windowSize) {
                sum += samples[index] * samples[index]
            }
            let rms = (sum / Float(windowSize)).squareRoot()
            levels.append(rms > 0 ? 20 * log10(rms) : -120)
            start += windowSize
        }
        let noiseFloor = levels.sorted()[levels.count / 5]
        let threshold = max(noiseFloor + marginAboveNoise, absoluteFloor)
        let voicedWindows = levels.filter { $0 > threshold }.count
        let needed = Int((minimumVoicedSeconds / 0.03).rounded(.up))
        return voicedWindows >= needed
    }
}
