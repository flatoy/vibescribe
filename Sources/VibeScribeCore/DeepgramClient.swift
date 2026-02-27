import Foundation
import AVFoundation

final class DeepgramClient: NSObject, @unchecked Sendable {
    private let session: URLSession
    private let queue = DispatchQueue(label: "VibeScribe.DeepgramClient")
    private let queueKey = DispatchSpecificKey<Void>()
    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isClosing = false
    private let onTranscriptEvent: (@Sendable (TranscriptEvent) -> Void)?
    private let onLog: (@Sendable (String, LogLevel) -> Void)?
    private var onClose: (() -> Void)?
    private var closeTimer: DispatchSourceTimer?

    init(
        onTranscriptEvent: (@Sendable (TranscriptEvent) -> Void)? = nil,
        onLog: (@Sendable (String, LogLevel) -> Void)? = nil
    ) {
        let configuration = URLSessionConfiguration.default
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        self.onTranscriptEvent = onTranscriptEvent
        self.onLog = onLog
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    func connect(
        apiKey: String,
        format: AudioStreamFormat,
        language: DeepgramLanguage
    ) {
        disconnect()

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"

        let queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(format.sampleRate)),
            URLQueryItem(name: "channels", value: String(format.channels)),
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: language.deepgramCode),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "100"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]

        components.queryItems = queryItems

        guard let url = components.url else {
            onLog?("Failed to build Deepgram URL.", .error)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        queue.sync {
            self.task = task
            self.isConnected = true
            self.isClosing = false
        }
        task.resume()
        onLog?("WebSocket connecting to \(url.absoluteString)", .info)

        receiveLoop()
    }

    func sendAudio(buffer: AVAudioPCMBuffer) {
        let task = queue.sync { isConnected ? self.task : nil }
        guard let task else { return }
        guard let data = AudioBufferConverter.linear16Data(from: buffer) else { return }

        task.send(.data(data)) { [weak self] error in
            if let error {
                self?.onLog?("WebSocket send error: \(error.localizedDescription)", .error)
            }
        }
    }

    func closeStream(onClosed: @escaping () -> Void) {
        let task = queue.sync { self.task }
        guard let task else {
            onClosed()
            return
        }

        queue.sync {
            isClosing = true
            onClose = onClosed
        }

        let closeMessage = "{\"type\":\"CloseStream\"}"
        task.send(.string(closeMessage)) { [weak self] error in
            if let error {
                self?.onLog?("Failed to send CloseStream: \(error.localizedDescription)", .error)
            } else {
                self?.onLog?("Sent CloseStream to Deepgram.", .info)
            }
        }

        scheduleCloseTimeout()
    }

    func disconnect() {
        queue.sync {
            isConnected = false
            isClosing = false
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            onClose = nil
        }
        closeTimer?.cancel()
        closeTimer = nil
        onLog?("WebSocket disconnected.", .info)
    }

    private func receiveLoop() {
        let task = queue.sync { self.task }
        guard let task else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncoming(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncoming(text: text)
                    }
                @unknown default:
                    break
                }
            case .failure(let error):
                let wasClosing = self.queue.sync { () -> Bool in
                    self.isConnected = false
                    return self.isClosing
                }
                if wasClosing {
                    self.finishClose()
                } else {
                    self.onLog?("WebSocket receive error: \(error.localizedDescription)", .error)
                }
                return
            }

            self.receiveLoop()
        }
    }

    private func handleIncoming(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let result = try? JSONDecoder().decode(DeepgramLiveResult.self, from: data) else {
            return
        }

        if let transcript = result.transcript, !transcript.isEmpty {
            let isFinal = (result.is_final ?? false) || (result.speech_final ?? false) || (result.from_finalize ?? false)
            let event = TranscriptEvent(
                text: transcript,
                isFinal: isFinal,
                isSpeechFinal: result.speech_final ?? false,
                receivedAt: Date()
            )
            onTranscriptEvent?(event)
        }

        if result.type == "Error", let description = result.errorDescription {
            onLog?("Deepgram error: \(description)", .error)
        }
    }

    private func scheduleCloseTimeout() {
        closeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0)
        timer.setEventHandler { [weak self] in
            self?.finishClose()
        }
        closeTimer = timer
        timer.activate()
    }

    private func finishClose() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            finishCloseOnQueue()
        } else {
            queue.async { [weak self] in
                self?.finishCloseOnQueue()
            }
        }
    }

    private func finishCloseOnQueue() {
        guard isClosing else { return }
        isClosing = false
        let callback = onClose
        onClose = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        closeTimer?.cancel()
        closeTimer = nil
        onLog?("WebSocket closed after CloseStream.", .info)
        callback?()
    }
}

private struct DeepgramLiveResult: Decodable {
    let type: String?
    let channel: DeepgramChannel?
    let is_final: Bool?
    let speech_final: Bool?
    let from_finalize: Bool?
    let errorDescription: String?

    var transcript: String? {
        channel?.alternatives?.first?.transcript
    }

    enum CodingKeys: String, CodingKey {
        case type
        case channel
        case is_final
        case speech_final
        case from_finalize
        case errorDescription = "description"
    }
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]?
}

private struct DeepgramAlternative: Decodable {
    let transcript: String?
}
