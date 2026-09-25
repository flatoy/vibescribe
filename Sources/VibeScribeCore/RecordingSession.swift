import AVFoundation
import Foundation

@MainActor
protocol RecordingSessionAudioCapture: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onConfigurationChanged: (() -> Void)? { get set }
    var inputDeviceUID: String? { get set }
    func start() throws -> AudioStreamFormat
    func stop()
}

enum TranscriptionOutcome: Sendable, Equatable {
    /// `language` is the Whisper code the model detected or was told to use.
    case success(String, language: String? = nil)
    case failure(String)
}

protocol RecordingSessionTranscription: AnyObject, Sendable {
    func start(language: WhisperLanguage) throws
    func sendAudio(buffer: AVAudioPCMBuffer)
    func finish(onFinished: @Sendable @escaping (TranscriptionOutcome) -> Void)
    func cancel()
}

struct FinalTranscript: Equatable, Sendable {
    let text: String
    let languageCode: String?
    let duration: TimeInterval

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// How a recording ended.
enum SessionEnd: Equatable, Sendable {
    case transcript(FinalTranscript)
    case noSpeech
    case failed(String)
    case couldNotStart(String)
    /// The input device changed mid-recording.
    case interrupted
}

@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case recording
        case finalizing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var sessionStartID: UUID = UUID()
    @Published private(set) var startedAt: Date?

    /// Live microphone level for the overlay and menu bar icon.
    let level = LevelMeter()

    private let audioCapture: any RecordingSessionAudioCapture
    private let transcription: any RecordingSessionTranscription
    private let transcript: TranscriptBuffer
    private let logger: Logger
    private var language: WhisperLanguage = .automatic
    private var recordedDuration: TimeInterval = 0

    var onEnded: ((SessionEnd) -> Void)?

    var isRecording: Bool { state == .recording }
    var isActive: Bool { state != .idle }

    init(
        audioCapture: any RecordingSessionAudioCapture,
        transcription: any RecordingSessionTranscription,
        transcript: TranscriptBuffer,
        logger: Logger
    ) {
        self.audioCapture = audioCapture
        self.transcription = transcription
        self.transcript = transcript
        self.logger = logger

        audioCapture.onConfigurationChanged = { [weak self] in
            self?.hopToMain {
                self?.handleAudioConfigurationChanged()
            }
        }
    }

    @discardableResult
    func start(language: WhisperLanguage, inputDeviceUID: String? = nil) -> Bool {
        guard state == .idle else { return false }

        do {
            try transcription.start(language: language)
            transcript.reset()
            self.language = language
            audioCapture.onBuffer = Self.bufferHandler(transcription: transcription, level: level)
            audioCapture.inputDeviceUID = inputDeviceUID
            let format = try audioCapture.start()
            logger.append("Audio capture started (\(format.sampleRate) Hz, \(format.channels) ch).", level: .info)
            state = .recording
            sessionStartID = UUID()
            startedAt = Date()
            statusMessage = "Listening..."
            logger.append("Language: \(language.displayName).", level: .info)
            logger.append("Listening started.", level: .info)
            return true
        } catch {
            audioCapture.stop()
            audioCapture.onBuffer = nil
            transcription.cancel()
            statusMessage = "Failed to start recording: \(error.localizedDescription)"
            logger.append(statusMessage, level: .error)
            onEnded?(.couldNotStart(error.localizedDescription))
            return false
        }
    }

    func stop() {
        guard state == .recording else { return }
        audioCapture.stop()
        audioCapture.onBuffer = nil
        recordedDuration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        level.reset()
        state = .finalizing
        statusMessage = "Transcribing..."
        logger.append(String(format: "Recording stopped · %.1f s", recordedDuration), level: .info)

        transcription.finish { @Sendable [weak self] outcome in
            self?.hopToMain {
                self?.finalizeStop(outcome)
            }
        }
    }

    func cancel() {
        guard state != .idle else { return }
        audioCapture.stop()
        audioCapture.onBuffer = nil
        transcription.cancel()
        level.reset()
        state = .idle
        startedAt = nil
        statusMessage = "Idle"
        transcript.reset()
        logger.append("Recording cancelled.", level: .info)
    }

    private func finalizeStop(_ outcome: TranscriptionOutcome) {
        guard state == .finalizing else { return }
        state = .idle
        startedAt = nil
        switch outcome {
        case .success(let text, let detected):
            transcript.handle(text, isFinal: true)
            let finalized = transcript.effectiveText
            if finalized.isEmpty {
                statusMessage = "No speech detected."
                logger.append("No speech heard. Nothing pasted.", level: .warning)
                onEnded?(.noSpeech)
            } else {
                statusMessage = "Ready"
                let result = FinalTranscript(
                    text: finalized,
                    languageCode: detected ?? language.whisperCode,
                    duration: recordedDuration
                )
                logger.append(
                    "Transcribed \(result.wordCount) words · \(result.languageCode ?? "auto")",
                    level: .info
                )
                onEnded?(.transcript(result))
            }
        case .failure(let message):
            statusMessage = "Transcription failed: \(message)"
            logger.append(statusMessage, level: .error)
            onEnded?(.failed(message))
        }
    }

    private func handleAudioConfigurationChanged() {
        logger.append("Audio input changed. Capture engine reset.", level: .warning)
        guard state == .recording else {
            statusMessage = "Audio input changed. Ready."
            return
        }
        cancel()
        statusMessage = "Input changed. Press the shortcut to try again."
        logger.append("Recording stopped because the input device changed.", level: .warning)
        onEnded?(.interrupted)
    }

    /// Built outside the main actor: buffers arrive on the audio thread.
    private nonisolated static func bufferHandler(
        transcription: any RecordingSessionTranscription,
        level: LevelMeter
    ) -> (AVAudioPCMBuffer) -> Void {
        { buffer in
            transcription.sendAudio(buffer: buffer)
            let value = LevelMeter.normalizedLevel(of: buffer)
            Task { @MainActor in level.push(value) }
        }
    }

    private nonisolated func hopToMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}

extension AudioCaptureController: RecordingSessionAudioCapture {}

/// Smoothed microphone level between 0 and 1.
@MainActor
final class LevelMeter: ObservableObject {
    @Published private(set) var level: Float = 0

    func push(_ value: Float) {
        // Fast attack, slower release, like a VU meter.
        let factor: Float = value > level ? 0.6 : 0.15
        level += (value - level) * factor
    }

    func reset() {
        level = 0
    }

    /// For previews and README screenshots.
    func simulate(_ value: Float) {
        level = value
    }

    /// Maps RMS to 0...1 on a -50...-10 dBFS scale, which covers normal speech.
    nonisolated static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            sum += samples[index] * samples[index]
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
