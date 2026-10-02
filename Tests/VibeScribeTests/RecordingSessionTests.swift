import AVFoundation
import Foundation
@testable import VibeScribeCore

@MainActor
private final class FakeAudioCapture: RecordingSessionAudioCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onConfigurationChanged: (() -> Void)?
    var inputDeviceUID: String?

    var startError: Error?
    var startCalls = 0
    var stopCalls = 0
    var nextFormat = AudioStreamFormat(sampleRate: 16000, channels: 1)

    func start() throws -> AudioStreamFormat {
        if let startError { throw startError }
        startCalls += 1
        return nextFormat
    }

    func stop() {
        stopCalls += 1
    }

    func fireConfigurationChanged() {
        onConfigurationChanged?()
    }
}

private final class FakeTranscription: RecordingSessionTranscription, @unchecked Sendable {
    var startError: Error?
    var startCalls = 0
    var sendCalls = 0
    var cancelCalls = 0
    var lastLanguage: WhisperLanguage?
    var pendingFinishCallbacks: [@Sendable (TranscriptionOutcome) -> Void] = []

    func start(language: WhisperLanguage) throws {
        if let startError { throw startError }
        startCalls += 1
        lastLanguage = language
    }

    func sendAudio(buffer: AVAudioPCMBuffer) {
        sendCalls += 1
    }

    func finish(onFinished: @Sendable @escaping (TranscriptionOutcome) -> Void) {
        pendingFinishCallbacks.append(onFinished)
    }

    func cancel() {
        cancelCalls += 1
    }

    func complete(_ outcome: TranscriptionOutcome) {
        let callbacks = pendingFinishCallbacks
        pendingFinishCallbacks.removeAll()
        for callback in callbacks { callback(outcome) }
    }
}

@MainActor
func runRecordingSessionTests(_ t: TestHarness) {
    func makeSession() -> (RecordingSession, FakeAudioCapture, FakeTranscription, TranscriptBuffer, Logger) {
        let audio = FakeAudioCapture()
        let transcription = FakeTranscription()
        let buffer = TranscriptBuffer()
        let logger = Logger()
        let session = RecordingSession(
            audioCapture: audio,
            transcription: transcription,
            transcript: buffer,
            logger: logger
        )
        return (session, audio, transcription, buffer, logger)
    }

    t.run("starts recording without a service key") {
        let (session, audio, transcription, _, _) = makeSession()
        t.expect(session.start(language: .english))

        t.expectEqual(session.state, .recording)
        t.expectEqual(audio.startCalls, 1)
        t.expectEqual(transcription.startCalls, 1)
        t.expectEqual(transcription.lastLanguage, .english)
    }

    t.run("buffer callback forwards audio to transcription") {
        let (session, audio, transcription, _, _) = makeSession()
        t.expect(session.start(language: .english))

        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        audio.onBuffer?(buffer)
        t.expectEqual(transcription.sendCalls, 1)
    }

    t.run("stop waits for local transcription before pasting") {
        let (session, audio, transcription, buffer, _) = makeSession()
        var finalized: [String] = []
        var ends: [SessionEnd] = []
        session.onEnded = { end in
            ends.append(end)
            if case .transcript(let transcript) = end { finalized.append(transcript.text) }
        }

        session.start(language: .english)
        session.stop()
        t.expectEqual(session.state, .finalizing)
        t.expectEqual(session.statusMessage, "Transcribing...")
        t.expectEqual(audio.stopCalls, 1)
        t.expectEqual(transcription.pendingFinishCallbacks.count, 1)
        t.expectEqual(finalized, [])

        transcription.complete(.success("hello"))
        t.expectEqual(session.state, .idle)
        t.expectEqual(buffer.final, "hello")
        t.expectEqual(finalized, ["hello"])
    }

    t.run("empty speech finishes without pasting") {
        let (session, _, transcription, _, _) = makeSession()
        var finalized: [String] = []
        var ends: [SessionEnd] = []
        session.onEnded = { end in
            ends.append(end)
            if case .transcript(let transcript) = end { finalized.append(transcript.text) }
        }

        session.start(language: .english)
        session.stop()
        transcription.complete(.success(""))
        t.expectEqual(session.state, .idle)
        t.expectEqual(session.statusMessage, "No speech detected.")
        t.expectEqual(finalized, [])
        t.expectEqual(ends, [.noSpeech])
    }

    t.run("transcription failure is visible and does not paste") {
        let (session, _, transcription, _, _) = makeSession()
        var finalized: [String] = []
        var errors = 0
        session.onEnded = { end in
            switch end {
            case .transcript(let transcript): finalized.append(transcript.text)
            case .failed, .couldNotStart: errors += 1
            default: break
            }
        }

        session.start(language: .english)
        session.stop()
        transcription.complete(.failure("Model unavailable"))
        t.expectEqual(session.state, .idle)
        t.expectEqual(session.statusMessage, "Transcription failed: Model unavailable")
        t.expectEqual(finalized, [])
        t.expectEqual(errors, 1)
    }

    t.run("cancel during recording does not paste") {
        let (session, audio, transcription, buffer, _) = makeSession()
        var finalized: [String] = []
        var ends: [SessionEnd] = []
        session.onEnded = { end in
            ends.append(end)
            if case .transcript(let transcript) = end { finalized.append(transcript.text) }
        }

        session.start(language: .english)
        session.cancel()
        t.expectEqual(session.state, .idle)
        t.expectEqual(audio.stopCalls, 1)
        t.expectEqual(transcription.cancelCalls, 1)
        t.expectEqual(buffer.final, "")
        t.expectEqual(finalized, [])
    }

    t.run("cancel during transcription ignores late completion") {
        let (session, _, transcription, _, _) = makeSession()
        var finalized: [String] = []
        var ends: [SessionEnd] = []
        session.onEnded = { end in
            ends.append(end)
            if case .transcript(let transcript) = end { finalized.append(transcript.text) }
        }

        session.start(language: .english)
        session.stop()
        session.cancel()
        transcription.complete(.success("too late"))
        t.expectEqual(session.state, .idle)
        t.expectEqual(finalized, [])
    }

    t.run("microphone change mid-recording restarts capture and keeps recording") {
        let (session, audio, transcription, _, _) = makeSession()
        var ends: [SessionEnd] = []
        session.onEnded = { ends.append($0) }
        session.start(language: .english)
        audio.nextFormat = AudioStreamFormat(sampleRate: 24000, channels: 1)
        audio.fireConfigurationChanged()
        t.expectEqual(session.state, .recording)
        t.expectEqual(audio.startCalls, 2)
        t.expectEqual(transcription.cancelCalls, 0)
        t.expectEqual(ends, [])

        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        audio.onBuffer?(buffer)
        t.expectEqual(transcription.sendCalls, 1)

        var pasted: [String] = []
        session.onEnded = { end in
            if case .transcript(let transcript) = end { pasted.append(transcript.text) }
        }
        session.stop()
        transcription.complete(.success("hello"))
        t.expectEqual(pasted, ["hello"])
    }

    t.run("microphone change while idle leaves state idle") {
        let (session, audio, _, _, _) = makeSession()
        audio.fireConfigurationChanged()
        t.expectEqual(session.state, .idle)
    }

    t.run("failed audio capture cancels prepared transcription") {
        let (session, audio, transcription, _, _) = makeSession()
        audio.startError = TestFailure(message: "Microphone unavailable")
        var errors = 0
        session.onEnded = { end in
            if case .couldNotStart = end { errors += 1 }
        }
        t.expect(!session.start(language: .english))
        t.expectEqual(session.state, .idle)
        t.expectEqual(transcription.cancelCalls, 1)
        t.expectEqual(errors, 1)
    }

    t.run("start while already recording is a no-op") {
        let (session, audio, transcription, _, _) = makeSession()
        session.start(language: .english)
        session.start(language: .english)
        t.expectEqual(audio.startCalls, 1)
        t.expectEqual(transcription.startCalls, 1)
    }

    t.run("sessionStartID changes on each recording") {
        let (session, _, transcription, _, _) = makeSession()
        let initialID = session.sessionStartID
        session.start(language: .english)
        let firstID = session.sessionStartID
        t.expect(initialID != firstID, "sessionStartID should change after start")

        session.stop()
        transcription.complete(.success(""))
        session.start(language: .english)
        t.expect(firstID != session.sessionStartID, "sessionStartID should change on second start")
    }

    t.run("transcript carries detected language, duration and word count") {
        let (session, _, transcription, _, _) = makeSession()
        var result: FinalTranscript?
        session.onEnded = { end in
            if case .transcript(let transcript) = end { result = transcript }
        }
        session.start(language: .automatic)
        session.stop()
        transcription.complete(.success("hei på deg", language: "no"))
        let transcript = try t.require(result)
        t.expectEqual(transcript.languageCode, "no")
        t.expectEqual(transcript.wordCount, 3)
        t.expect(transcript.duration >= 0)
    }

    t.run("chosen language is used when the model reports none") {
        let (session, _, transcription, _, _) = makeSession()
        var result: FinalTranscript?
        session.onEnded = { end in
            if case .transcript(let transcript) = end { result = transcript }
        }
        session.start(language: .english)
        session.stop()
        transcription.complete(.success("hello"))
        t.expectEqual(result?.languageCode, "en")
    }

    t.run("start passes the chosen microphone to capture") {
        let (session, audio, _, _, _) = makeSession()
        session.start(language: .english, inputDeviceUID: "usb-mic")
        t.expectEqual(audio.inputDeviceUID, "usb-mic")
    }

    t.run("microphone change reports an interruption when capture cannot restart") {
        let (session, audio, transcription, _, _) = makeSession()
        var ends: [SessionEnd] = []
        session.onEnded = { ends.append($0) }
        session.start(language: .english)
        audio.startError = TestFailure(message: "Microphone unavailable")
        audio.fireConfigurationChanged()
        t.expectEqual(session.state, .idle)
        t.expectEqual(transcription.cancelCalls, 1)
        t.expectEqual(ends, [.interrupted])
    }

    t.run("a microphone that keeps changing format interrupts after a few restarts") {
        let (session, audio, _, _, _) = makeSession()
        var ends: [SessionEnd] = []
        session.onEnded = { ends.append($0) }
        session.start(language: .english)
        for _ in 0..<RecordingSession.maxCaptureRestarts { audio.fireConfigurationChanged() }
        t.expectEqual(session.state, .recording)
        t.expectEqual(ends, [])

        audio.fireConfigurationChanged()
        t.expectEqual(session.state, .idle)
        t.expectEqual(audio.startCalls, 1 + RecordingSession.maxCaptureRestarts)
        t.expectEqual(ends, [.interrupted])
    }

    t.run("capture ignores a configuration notice from its own microphone selection") {
        t.expectEqual(
            AudioCaptureController.action(engineRunning: true, formatUnchanged: true, inPlaceRestarts: 0),
            .ignore
        )
    }

    t.run("capture restarts in place when the engine stopped but the format is the same") {
        t.expectEqual(
            AudioCaptureController.action(engineRunning: false, formatUnchanged: true, inPlaceRestarts: 0),
            .restartInPlace
        )
        t.expectEqual(
            AudioCaptureController.action(
                engineRunning: false,
                formatUnchanged: true,
                inPlaceRestarts: AudioCaptureController.maxInPlaceRestarts
            ),
            .rebuild
        )
    }

    t.run("capture rebuilds when the microphone format changes") {
        t.expectEqual(
            AudioCaptureController.action(engineRunning: false, formatUnchanged: false, inPlaceRestarts: 0),
            .rebuild
        )
        t.expectEqual(
            AudioCaptureController.action(engineRunning: true, formatUnchanged: false, inPlaceRestarts: 0),
            .rebuild
        )
    }

    t.run("each recording gets its own restart allowance") {
        let (session, audio, transcription, _, _) = makeSession()
        var ends: [SessionEnd] = []
        session.onEnded = { ends.append($0) }
        session.start(language: .english)
        for _ in 0..<RecordingSession.maxCaptureRestarts { audio.fireConfigurationChanged() }
        session.stop()
        transcription.complete(.success(""))

        session.start(language: .english)
        audio.fireConfigurationChanged()
        t.expectEqual(session.state, .recording)
        t.expectEqual(ends, [.noSpeech])
    }
}
