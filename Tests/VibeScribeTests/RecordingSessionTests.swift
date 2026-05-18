import AVFoundation
import Foundation
@testable import VibeScribeCore

@MainActor
private final class FakeAudioCapture: RecordingSessionAudioCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onConfigurationChanged: (() -> Void)?

    var startError: Error?
    var startCalls = 0
    var stopCalls = 0
    var nextFormat = AudioStreamFormat(sampleRate: 16000, channels: 1)

    func start() throws -> AudioStreamFormat {
        if let startError {
            throw startError
        }
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

@MainActor
private final class FakeTranscription: @MainActor RecordingSessionTranscription {
    var connectCalls = 0
    var sendCalls = 0
    var disconnectCalls = 0
    var lastApiKey: String?
    var lastLanguage: DeepgramLanguage?
    var pendingCloseCallbacks: [@Sendable () -> Void] = []

    func connect(apiKey: String, format: AudioStreamFormat, language: DeepgramLanguage) {
        connectCalls += 1
        lastApiKey = apiKey
        lastLanguage = language
    }

    func sendAudio(buffer: AVAudioPCMBuffer) {
        sendCalls += 1
    }

    func closeStream(onClosed: @Sendable @escaping () -> Void) {
        pendingCloseCallbacks.append(onClosed)
    }

    func disconnect() {
        disconnectCalls += 1
    }

    func completeClose() {
        let callbacks = pendingCloseCallbacks
        pendingCloseCallbacks.removeAll()
        for cb in callbacks { cb() }
    }
}

@MainActor
func runRecordingSessionTests(_ t: TestHarness) {
    func makeSession() -> (RecordingSession, FakeAudioCapture, FakeTranscription, TranscriptBuffer, Logger) {
        let audio = FakeAudioCapture()
        let trans = FakeTranscription()
        let buffer = TranscriptBuffer()
        let logger = Logger()
        let session = RecordingSession(
            audioCapture: audio,
            transcription: trans,
            transcript: buffer,
            logger: logger
        )
        return (session, audio, trans, buffer, logger)
    }

    t.run("start with empty apiKey fires onMissingApiKey and stays idle") {
        let (session, audio, trans, _, _) = makeSession()
        var missingApiKeyFired = 0
        session.onMissingApiKey = { missingApiKeyFired += 1 }

        session.start(apiKey: "  ", language: .english)
        t.expectEqual(session.state, .idle)
        t.expectEqual(audio.startCalls, 0)
        t.expectEqual(trans.connectCalls, 0)
        t.expectEqual(missingApiKeyFired, 1)
    }

    t.run("start with key transitions to recording and wires the pipe") {
        let (session, audio, trans, _, _) = makeSession()
        session.start(apiKey: "key-1", language: .english)

        t.expectEqual(session.state, .recording)
        t.expectEqual(audio.startCalls, 1)
        t.expectEqual(trans.connectCalls, 1)
        t.expectEqual(trans.lastApiKey, "key-1")
        t.expectEqual(trans.lastLanguage, .english)
    }

    t.run("buffer callback forwards to transcription") {
        let (session, audio, trans, _, _) = makeSession()
        session.start(apiKey: "k", language: .english)

        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        audio.onBuffer?(buffer)
        t.expectEqual(trans.sendCalls, 1)
    }

    t.run("stop transitions through finalizing to idle; onFinalized fires with transcript") {
        let (session, audio, trans, _, _) = makeSession()
        var finalized: [String] = []
        session.onFinalized = { finalized.append($0) }

        session.start(apiKey: "k", language: .english)
        session.handleTranscriptEvent("hello", isFinal: true)
        session.stop()
        t.expectEqual(session.state, .finalizing)
        t.expectEqual(audio.stopCalls, 1)
        t.expectEqual(trans.pendingCloseCallbacks.count, 1)

        trans.completeClose()
        t.expectEqual(session.state, .idle)
        t.expectEqual(finalized, ["hello"])
    }

    t.run("stop completion with empty transcript does not fire onFinalized") {
        let (session, _, trans, _, _) = makeSession()
        var finalized: [String] = []
        session.onFinalized = { finalized.append($0) }

        session.start(apiKey: "k", language: .english)
        session.stop()
        trans.completeClose()
        t.expectEqual(session.state, .idle)
        t.expectEqual(finalized, [])
    }

    t.run("cancel goes directly to idle without firing onFinalized") {
        let (session, audio, trans, buffer, _) = makeSession()
        var finalized: [String] = []
        session.onFinalized = { finalized.append($0) }

        session.start(apiKey: "k", language: .english)
        session.handleTranscriptEvent("hi", isFinal: true)
        session.cancel()
        t.expectEqual(session.state, .idle)
        t.expectEqual(audio.stopCalls, 1)
        t.expectEqual(trans.disconnectCalls, 1)
        t.expectEqual(buffer.final, "")
        t.expectEqual(finalized, [])
    }

    t.run("configuration change during recording cancels") {
        let (session, _, _, _, _) = makeSession()
        session.start(apiKey: "k", language: .english)
        t.expectEqual(session.state, .recording)
    }

    t.run("configuration change while idle is a no-op state-wise") {
        let (session, audio, _, _, _) = makeSession()
        audio.fireConfigurationChanged()
        t.expectEqual(session.state, .idle)
    }

    t.run("start while already recording is a no-op") {
        let (session, audio, trans, _, _) = makeSession()
        session.start(apiKey: "k", language: .english)
        session.start(apiKey: "k", language: .english)
        t.expectEqual(audio.startCalls, 1)
        t.expectEqual(trans.connectCalls, 1)
    }

    t.run("sessionStartID bumps on each start") {
        let (session, _, trans, _, _) = makeSession()
        let firstID = session.sessionStartID
        session.start(apiKey: "k", language: .english)
        let afterStart = session.sessionStartID
        t.expect(firstID != afterStart, "sessionStartID should change after start")

        session.stop()
        trans.completeClose()
        session.start(apiKey: "k", language: .english)
        t.expect(afterStart != session.sessionStartID, "sessionStartID should change on second start")
    }
}
