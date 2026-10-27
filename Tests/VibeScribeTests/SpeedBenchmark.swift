import Foundation
@testable import VibeScribeCore

/// Times a downloaded model on one recording: the median of three runs after a warm-up, in English.
/// `SpeechModelID.secondsPerMinute` comes from this with a minute of speech.
@MainActor
func runSpeedBenchmark(_ t: TestHarness, model: SpeechModelID, modelFolder: String, audioPath: String) async {
    func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    do {
        let engine = model.makeEngine(modelFolder: URL(fileURLWithPath: modelFolder, isDirectory: true))
        let loadStart = uptime()
        try await engine.prepare()
        let loadTime = uptime() - loadStart
        let segments = [try readAudioFile(audioPath)]
        let seconds = Double(segments[0].samples.count) / segments[0].sampleRate
        _ = try await engine.transcribe(segments: segments, language: .english, vocabulary: "")
        var times: [TimeInterval] = []
        var text = ""
        for _ in 0..<3 {
            let began = uptime()
            text = try await engine.transcribe(segments: segments, language: .english, vocabulary: "").text
            times.append(uptime() - began)
        }
        let median = times.sorted()[1]
        t.run("\(model.shortName) transcribes \(String(format: "%.0f", seconds)) s of audio") {
            print("  load \(String(format: "%.1f", loadTime))s · runs \(times.map { String(format: "%.2f", $0) }.joined(separator: ", "))s")
            print("  \(String(format: "%.2f", median * 60 / seconds)) s per minute of audio")
            print("  \(text)")
            t.expect(!text.isEmpty, "Expected a nonempty transcript")
        }
    } catch {
        t.run("\(model.shortName) benchmark") { throw error }
    }
}
