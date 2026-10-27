import AVFoundation
import Foundation
@testable import VibeScribeCore

@MainActor
func runBarkTests(_ t: TestHarness) {
    t.run("short recordings are transcribed in one piece") {
        let audio = [Float](repeating: 0.1, count: 14 * BarkAudio.sampleRate)
        t.expectEqual(BarkAudio.pieces(of: audio, maxSeconds: 14.75).count, 1)
    }

    t.run("long recordings are cut in the quietest pause") {
        let rate = BarkAudio.sampleRate
        // Speech-like noise with one near-silent stretch at 9 to 9.4 seconds.
        var generator = SystemRandomNumberGenerator()
        var audio = (0..<(20 * rate)).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
        for index in (9 * rate)..<(9 * rate + rate * 2 / 5) { audio[index] *= 0.001 }
        let pieces = BarkAudio.pieces(of: audio, maxSeconds: 14.75)
        t.expectEqual(pieces.count, 2)
        let cut = pieces[0].count
        t.expect(cut > 9 * rate && cut < 9 * rate + rate * 2 / 5, "cut at \(Double(cut) / Double(rate)) s")
        t.expectEqual(pieces.flatMap { $0 }, audio)
        t.expect(pieces.allSatisfy { $0.count <= Int(14.75 * Double(rate)) })
    }

    t.run("encoder length follows three stride-2 convolutions") {
        t.expectEqual(BarkFrontend.encodedLength(1501), 188)
        t.expectEqual(BarkFrontend.encodedLength(801), 101)
        t.expectEqual(BarkFrontend.encodedLength(25), 4)
    }
}

/// A whole audio file as mono samples. One read can stop short of the end.
func readAudioFile(_ path: String) throws -> AudioSegment {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    var samples: [Float] = []
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let mono = AudioBufferConverter.monoSamples(from: buffer) else { break }
        samples += mono
    }
    return AudioSegment(sampleRate: file.processingFormat.sampleRate, samples: samples)
}

/// Transcribes local clips with a downloaded Bark model, timing each one after a warm-up.
@MainActor
func runBarkModelSmoke(_ t: TestHarness, modelFolder: String, audioPaths: [String]) async {
    guard #available(macOS 15, *) else {
        t.run("Bark needs macOS 15") {}
        return
    }
    do {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let engine = BarkEngine(modelFolder: URL(fileURLWithPath: modelFolder, isDirectory: true))
        try await engine.prepare()
        print("  Model loaded in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt))s")
        for path in audioPaths {
            let segments = [try readAudioFile(path)]
            _ = try await engine.transcribe(segments: segments, language: .english, vocabulary: "")
            let began = ProcessInfo.processInfo.systemUptime
            let result = try await engine.transcribe(segments: segments, language: .english, vocabulary: "")
            let took = ProcessInfo.processInfo.systemUptime - began
            t.run("Bark transcribes \((path as NSString).lastPathComponent)") {
                print("  \(String(format: "%.3f", took))s | \(result.text)")
                t.expect(!result.text.isEmpty, "Expected a nonempty transcript")
            }
        }
    } catch {
        t.run("Bark model") { throw error }
    }
}
