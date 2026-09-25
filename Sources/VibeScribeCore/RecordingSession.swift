import AVFoundation
import Foundation

@MainActor
protocol RecordingSessionAudioCapture: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onConfigurationChanged: (() -> Void)? { get set }
    func start() throws -> AudioStreamFormat
    func stop()
}

enum TranscriptionOutcome: Sendable, Equatable {
    case success(String)
    case failure(String)
}

protocol RecordingSessionTranscription: AnyObject, Sendable {
    func start(language: WhisperLanguage) throws
    func sendAudio(buffer: AVAudioPCMBuffer)
    func finish(onFinished: @Sendable @escaping (TranscriptionOutcome) -> Void)
    func cancel()
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

    private let audioCapture: any RecordingSessionAudioCapture
    private let transcription: any RecordingSessionTranscription
    private let transcript: TranscriptBuffer
    private let logger: Logger

    var onFinalized: ((String) -> Void)?
    var onError: (() -> Void)?

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
    func start(language: WhisperLanguage) -> Bool {
        guard state == .idle else { return false }

        do {
            try transcription.start(language: language)
            transcript.reset()
            let transcription = self.transcription
            audioCapture.onBuffer = { buffer in
                transcription.sendAudio(buffer: buffer)
            }
            let format = try audioCapture.start()
            logger.append("Audio capture started (\(format.sampleRate) Hz, \(format.channels) ch).", level: .info)
            state = .recording
            sessionStartID = UUID()
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
            onError?()
            return false
        }
    }

    func stop() {
        guard state == .recording else { return }
        audioCapture.stop()
        audioCapture.onBuffer = nil
        state = .finalizing
        statusMessage = "Transcribing..."

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
        state = .idle
        statusMessage = "Idle"
        transcript.reset()
    }

    private func finalizeStop(_ outcome: TranscriptionOutcome) {
        guard state == .finalizing else { return }
        state = .idle
        logger.append("Listening stopped.", level: .info)
        switch outcome {
        case .success(let text):
            transcript.handle(text, isFinal: true)
            let finalized = transcript.effectiveText
            if finalized.isEmpty {
                statusMessage = "No speech detected."
                logger.append("No transcript to paste.", level: .warning)
            } else {
                statusMessage = "Ready"
                onFinalized?(finalized)
            }
        case .failure(let message):
            statusMessage = "Transcription failed: \(message)"
            logger.append(statusMessage, level: .error)
            onError?()
        }
    }

    private func handleAudioConfigurationChanged() {
        logger.append("Audio input changed. Capture engine reset.", level: .warning)
        guard state == .recording else {
            statusMessage = "Audio input changed. Ready."
            return
        }
        cancel()
        statusMessage = "Input changed. Press and hold Option to resume."
        logger.append("Recording stopped because the input device changed.", level: .warning)
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
