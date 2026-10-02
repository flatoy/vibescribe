// `envelope`: the app's meter level from a WAV, using LevelMeter itself.
// `test-envelope`: a synthetic sine envelope for trying the sequence renderer.

import AVFoundation
import Foundation
@testable import VibeScribeCore

/// Mono samples at 48 kHz (channel 0, as the app's tap reads it), linearly resampled if needed.
func loadMono48k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let total = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else { throw ToolError("can’t allocate \(total) frames") }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else { throw ToolError("\(url.path): not float PCM after decoding") }
    let count = Int(buffer.frameLength)
    let source = Array(UnsafeBufferPointer(start: channels[0], count: count))
    let rate = format.sampleRate
    if abs(rate - 48000) < 0.5 { return source }
    let outCount = Int((Double(count) * 48000 / rate).rounded())
    return (0..<outCount).map { i in
        let position = Double(i) * rate / 48000
        let j = Int(position)
        let frac = Float(position - Double(j))
        let a = source[min(j, count - 1)], b = source[min(j + 1, count - 1)]
        return a + (b - a) * frac
    }
}

/// LevelMeter.level after each tap buffer: (buffer end time, level).
@MainActor
func meterTrack(samples: [Float], bufferFrames: Int, tail: Double) -> [(Double, Float)] {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let meter = LevelMeter()
    var track: [(Double, Float)] = []
    let tailFrames = Int(tail * 48000)
    var start = 0
    while start < samples.count + tailFrames {
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bufferFrames))!
        chunk.frameLength = AVAudioFrameCount(bufferFrames)
        let pointer = chunk.floatChannelData![0]
        for k in 0..<bufferFrames {
            let index = start + k
            pointer[k] = index < samples.count ? samples[index] : 0
        }
        meter.push(LevelMeter.normalizedLevel(of: chunk))
        start += bufferFrames
        track.append((Double(start) / 48000, meter.level))
    }
    return track
}

/// Samples a meter track at `fps`: the level after the last buffer delivered by each frame time.
func sampleTrack(_ track: [(Double, Float)], fps: Double, duration: Double) -> [Float] {
    let count = Int((duration * fps).rounded(.up))
    var levels: [Float] = []
    var cursor = -1
    for i in 0..<count {
        let t = Double(i) / fps
        while cursor + 1 < track.count, track[cursor + 1].0 <= t + 1e-9 { cursor += 1 }
        levels.append(cursor >= 0 ? track[cursor].1 : 0)
    }
    return levels
}

func rounded4(_ values: [Float]) -> [Double] { values.map { (Double($0) * 10000).rounded() / 10000 } }

@MainActor
func runEnvelope(_ args: Arguments) throws {
    let wav = URL(fileURLWithPath: try args.value("--wav").orThrow("--wav FILE is required"))
    let out = URL(fileURLWithPath: try args.value("--out").orThrow("--out FILE is required"))
    let fps = try args.double("--fps") ?? 60
    let bufferFrames = try args.int("--buffer-frames") ?? 1024
    let tail = try args.double("--tail") ?? 0.6
    let samples = try loadMono48k(wav)
    let duration = Double(samples.count) / 48000
    let track = meterTrack(samples: samples, bufferFrames: bufferFrames, tail: tail)
    let levels = sampleTrack(track, fps: fps, duration: duration + tail)
    try ensureDirectory(out.deletingLastPathComponent())
    try writeJSON([
        "fps": fps,
        "levels": rounded4(levels),
        "kind": "level",
        "source": wav.lastPathComponent,
        "duration": (duration * 1000).rounded() / 1000,
        "tail_s": tail,
        "buffer_frames": bufferFrames,
        "sample_rate": 48000,
        "rule": "levels[i] = VibeScribeCore LevelMeter.level after the last \(bufferFrames)-frame buffer (48 kHz, channel 0) ending at or before i/fps; computed with LevelMeter.normalizedLevel(of:) and LevelMeter.push(_:).",
    ], to: out)
    print("wrote \(out.path): \(levels.count) levels at \(fps) fps (\(String(format: "%.2f", duration)) s + \(tail) s tail), peak \(String(format: "%.3f", levels.max() ?? 0))")
}

@MainActor
func runTestEnvelope(_ args: Arguments) throws {
    let out = URL(fileURLWithPath: try args.value("--out").orThrow("--out FILE is required"))
    let fps = try args.double("--fps") ?? 60
    let lead = try args.double("--lead") ?? 0.25
    let voiced = try args.double("--duration") ?? 4
    let tail = try args.double("--tail") ?? 0.6
    let hz = try args.double("--hz") ?? 2.2
    // Targets: silence, then a sine between ~0.25 and ~0.95 (speech-like loudness), then silence.
    // They go through the real LevelMeter at the tap's buffer rate, so the result is a meter level.
    let total = lead + voiced + tail
    let meter = LevelMeter()
    var track: [(Double, Float)] = []
    var k = 0
    while Double(k) * Envelope.bufferDuration < total {
        let t = Double(k) * Envelope.bufferDuration
        let inVoice = t >= lead && t < lead + voiced
        let target: Float = inVoice ? Float(0.6 + 0.35 * cos(2 * Double.pi * hz * (t - lead))) : 0
        meter.push(min(max(target, 0), 1))
        k += 1
        track.append((Double(k) * Envelope.bufferDuration, meter.level))
    }
    let levels = sampleTrack(track, fps: fps, duration: total)
    try ensureDirectory(out.deletingLastPathComponent())
    try writeJSON([
        "fps": fps,
        "levels": rounded4(levels),
        "kind": "level",
        "synthetic": "sine \(hz) Hz, targets 0.6 + 0.35*cos(2*pi*\(hz)*t) from \(lead) s for \(voiced) s, smoothed by LevelMeter at 46.875 buffers/s",
        "duration": total,
    ], to: out)
    print("wrote \(out.path): \(levels.count) levels at \(fps) fps")
}
