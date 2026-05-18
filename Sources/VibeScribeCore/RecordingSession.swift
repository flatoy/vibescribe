import AVFoundation
import Foundation

@MainActor
protocol RecordingSessionAudioCapture: AnyObject {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onConfigurationChanged: (() -> Void)? { get set }
    func start() throws -> AudioStreamFormat
    func stop()
}

protocol RecordingSessionTranscription: AnyObject {
    func connect(apiKey: String, format: AudioStreamFormat, language: DeepgramLanguage)
    func sendAudio(buffer: AVAudioPCMBuffer)
    func closeStream(onClosed: @escaping () -> Void)
    func disconnect()
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
    var onMissingApiKey: (() -> Void)?

    var isRecording: Bool { state == .recording }

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

    func start(apiKey: String, language: DeepgramLanguage) {
        guard state == .idle else { return }

        let trimmedKey = apiKey.trimmed
        guard !trimmedKey.isEmpty else {
            statusMessage = "Add a Deepgram API key in Settings."
            logger.append("Missing API key. Open Settings to add one.", level: .warning)
            onMissingApiKey?()
            return
        }

        do {
            transcript.reset()
            let format = try audioCapture.start()
            logger.append("Audio capture started (\(format.sampleRate) Hz, \(format.channels) ch).", level: .info)
            transcription.connect(apiKey: trimmedKey, format: format, language: language)
            audioCapture.onBuffer = { [weak self] buffer in
                self?.transcription.sendAudio(buffer: buffer)
            }
            state = .recording
            sessionStartID = UUID()
            statusMessage = "Listening..."
            logger.append("Language: \(language.displayName) (\(language.deepgramCode)).", level: .info)
            logger.append("Listening started.", level: .info)
        } catch {
            statusMessage = "Failed to start audio capture: \(error.localizedDescription)"
            logger.append("Failed to start audio capture: \(error.localizedDescription)", level: .error)
        }
    }

    func stop() {
        guard state == .recording else { return }
        audioCapture.stop()
        state = .finalizing
        statusMessage = "Finalizing..."

        transcription.closeStream { [weak self] in
            self?.hopToMain {
                self?.finalizeStop()
            }
        }
    }

    func cancel() {
        guard state != .idle else { return }
        audioCapture.stop()
        transcription.disconnect()
        state = .idle
        statusMessage = "Idle"
        transcript.reset()
    }

    func handleTranscriptEvent(_ text: String, isFinal: Bool) {
        transcript.handle(text, isFinal: isFinal)
    }

    private func finalizeStop() {
        guard state == .finalizing else { return }
        state = .idle
        statusMessage = "Idle"
        logger.append("Listening stopped.", level: .info)
        let text = transcript.effectiveText
        if text.isEmpty {
            logger.append("No transcript to paste.", level: .warning)
            return
        }
        onFinalized?(text)
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
extension DeepgramClient: RecordingSessionTranscription {}
