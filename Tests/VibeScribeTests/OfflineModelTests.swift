import AVFoundation
import Foundation
import WhisperKit
@testable import VibeScribeCore

@MainActor
func runOfflineModelSmoke(
    _ t: TestHarness,
    modelFolder: String,
    audioPath: String,
    language: WhisperLanguage,
    requiredTerms: [String]
) async {
    do {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let folder = URL(fileURLWithPath: modelFolder, isDirectory: true)
        let tokenizerData = try Data(contentsOf: folder.appendingPathComponent("tokenizer.json"))
        let tokenizer = try JSONSerialization.jsonObject(with: tokenizerData) as? [String: Any]
        let addedTokens = tokenizer?["added_tokens"] as? [[String: Any]] ?? []
        let tokenStrings = Set(addedTokens.compactMap { $0["content"] as? String })
        t.run("language picker matches downloaded tokenizer") {
            let pickerCodes = Set(WhisperLanguage.allCases.compactMap(\.whisperCode))
            let tokenCodes = Set(Constants.languageCodes.filter { tokenStrings.contains("<|\($0)|>") })
            t.expectEqual(pickerCodes, tokenCodes)
        }

        let client = WhisperKitClient(modelFolder: folder) { message, level in
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            print("  \(level.rawValue) \(message) (\(String(format: "%.1f", elapsed))s)")
        }
        try await client.prepare()

        /// With `switchingRate`, the last two thirds arrive at another sample rate, the way
        /// AirPods switch once their microphone opens.
        func transcribe(_ language: WhisperLanguage, switchingRate: Bool = false) async throws -> TranscriptionOutcome {
            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
            let switchedRate: Double = audioFile.processingFormat.sampleRate == 24_000 ? 48_000 : 24_000
            try client.start(language: language)
            while audioFile.framePosition < audioFile.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 4096)!
                try audioFile.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                if switchingRate, audioFile.framePosition > audioFile.length / 3 {
                    guard let switched = AudioProcessor.resampleAudio(
                        fromBuffer: buffer,
                        toSampleRate: switchedRate,
                        channelCount: buffer.format.channelCount
                    ) else { throw TestFailure(message: "Could not resample the test audio") }
                    client.sendAudio(buffer: switched)
                } else {
                    client.sendAudio(buffer: buffer)
                }
            }
            return await withCheckedContinuation { continuation in
                client.finish { result in
                    continuation.resume(returning: result)
                }
            }
        }

        let selectedOutcome = try await transcribe(language)
        print("  Selected transcription finished at \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt))s")
        t.run("local WhisperKit model transcribes audio as \(language.displayName)") {
            switch selectedOutcome {
            case .success(let text, let detected):
                print("  Transcript (\(detected ?? "?")): \(text)")
                t.expect(!text.isEmpty, "Expected a nonempty transcript")
                for term in requiredTerms {
                    t.expect(text.localizedCaseInsensitiveContains(term), "Missing expected term: \(term)")
                }
            case .failure(let message):
                t.expect(false, "Transcription failed: \(message)")
            }
        }

        let switchedOutcome = try await transcribe(language, switchingRate: true)
        t.run("a sample rate change mid-recording still transcribes") {
            switch switchedOutcome {
            case .success(let text, _):
                print("  Transcript across the rate change: \(text)")
                t.expect(!text.isEmpty, "Expected a nonempty transcript")
                for term in requiredTerms {
                    t.expect(text.localizedCaseInsensitiveContains(term), "Missing expected term: \(term)")
                }
            case .failure(let message):
                t.expect(false, "Transcription failed: \(message)")
            }
        }

        let automaticOutcome = try await transcribe(.automatic)
        print("  Automatic transcription finished at \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startedAt))s")
        t.run("automatic language detection transcribes local audio") {
            switch automaticOutcome {
            case .success(let text, let detected):
                print("  Automatic transcript (\(detected ?? "?")): \(text)")
                t.expect(!text.isEmpty, "Expected a nonempty transcript")
            case .failure(let message):
                t.expect(false, "Transcription failed: \(message)")
            }
        }

        client.setVocabulary("VibeScribe, WhisperKit, Flåtøy")
        let vocabularyOutcome = try await transcribe(language)
        client.setVocabulary("")
        t.run("vocabulary prompt still transcribes local audio") {
            switch vocabularyOutcome {
            case .success(let text, _):
                print("  Transcript with vocabulary: \(text)")
                t.expect(!text.isEmpty, "Expected a nonempty transcript")
                for term in requiredTerms {
                    t.expect(text.localizedCaseInsensitiveContains(term), "Missing expected term: \(term)")
                }
            case .failure(let message):
                t.expect(false, "Transcription failed: \(message)")
            }
        }

    } catch {
        t.run("local WhisperKit model transcribes audio") {
            throw error
        }
    }
}
