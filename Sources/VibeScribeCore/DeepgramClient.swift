import AVFoundation
import Foundation

actor DeepgramClient {
    enum ParseResult: Equatable {
        case transcript(text: String, isFinal: Bool)
        case errorMessage(String)
    }

    nonisolated let onTranscriptEvent: (@Sendable (String, Bool) -> Void)?
    nonisolated let onLog: (@Sendable (String, LogLevel) -> Void)?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isClosing = false
    private var onClose: (@Sendable () -> Void)?
    private var closeTimerTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    init(
        onTranscriptEvent: (@Sendable (String, Bool) -> Void)? = nil,
        onLog: (@Sendable (String, LogLevel) -> Void)? = nil
    ) {
        let configuration = URLSessionConfiguration.default
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        self.onTranscriptEvent = onTranscriptEvent
        self.onLog = onLog
    }

    // MARK: - Nonisolated entry points

    nonisolated func connect(apiKey: String, format: AudioStreamFormat, language: DeepgramLanguage) {
        Task { [weak self] in
            await self?.performConnect(apiKey: apiKey, format: format, language: language)
        }
    }

    nonisolated func sendAudio(buffer: AVAudioPCMBuffer) {
        guard let data = AudioBufferConverter.linear16Data(from: buffer) else { return }
        Task { [weak self] in
            await self?.performSend(data: data)
        }
    }

    nonisolated func closeStream(onClosed: @Sendable @escaping () -> Void) {
        Task { [weak self] in
            await self?.performCloseStream(onClosed: onClosed)
        }
    }

    nonisolated func disconnect() {
        Task { [weak self] in
            await self?.performDisconnect()
        }
    }

    // MARK: - Isolated logic

    private func performConnect(apiKey: String, format: AudioStreamFormat, language: DeepgramLanguage) {
        disconnectInternal()

        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.deepgram.com"
        components.path = "/v1/listen"
        components.queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(format.sampleRate)),
            URLQueryItem(name: "channels", value: String(format.channels)),
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: language.deepgramCode),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "endpointing", value: "100"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]

        guard let url = components.url else {
            onLog?("Failed to build Deepgram URL.", .error)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        self.task = task
        self.isConnected = true
        self.isClosing = false
        task.resume()
        onLog?("WebSocket connecting to \(url.absoluteString)", .info)

        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func performSend(data: Data) {
        guard isConnected, let task else { return }
        let logger = onLog
        task.send(.data(data)) { error in
            if let error {
                logger?("WebSocket send error: \(error.localizedDescription)", .error)
            }
        }
    }

    private func performCloseStream(onClosed: @Sendable @escaping () -> Void) {
        guard let task else {
            onClosed()
            return
        }

        isClosing = true
        self.onClose = onClosed

        let closeMessage = "{\"type\":\"CloseStream\"}"
        let logger = onLog
        task.send(.string(closeMessage)) { error in
            if let error {
                logger?("Failed to send CloseStream: \(error.localizedDescription)", .error)
            } else {
                logger?("Sent CloseStream to Deepgram.", .info)
            }
        }

        scheduleCloseTimeout()
    }

    private func performDisconnect() {
        disconnectInternal()
        onLog?("WebSocket disconnected.", .info)
    }

    private func disconnectInternal() {
        isConnected = false
        isClosing = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onClose = nil
        closeTimerTask?.cancel()
        closeTimerTask = nil
        receiveTask?.cancel()
        receiveTask = nil
    }

    private func scheduleCloseTimeout() {
        closeTimerTask?.cancel()
        closeTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.finalizeClose()
        }
    }

    private func finalizeClose() {
        guard isClosing else { return }
        isClosing = false
        let callback = onClose
        onClose = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        closeTimerTask?.cancel()
        closeTimerTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        onLog?("WebSocket closed after CloseStream.", .info)
        callback?()
    }

    private func runReceiveLoop() async {
        while !Task.isCancelled, isConnected, let task {
            do {
                let message = try await task.receive()
                if Task.isCancelled { return }
                switch message {
                case .string(let text):
                    handleIncoming(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleIncoming(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                isConnected = false
                if isClosing {
                    finalizeClose()
                    return
                }
                onLog?("WebSocket receive error: \(error.localizedDescription)", .error)
                return
            }
        }
    }

    private func handleIncoming(text: String) {
        guard let result = Self.parseMessage(text) else { return }
        switch result {
        case .transcript(let text, let isFinal):
            onTranscriptEvent?(text, isFinal)
        case .errorMessage(let message):
            onLog?("Deepgram error: \(message)", .error)
        }
    }

    // MARK: - Pure parsing (testable)

    nonisolated static func parseMessage(_ text: String) -> ParseResult? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let result = try? JSONDecoder().decode(DeepgramLiveResult.self, from: data) else {
            return nil
        }

        if let transcript = result.transcript, !transcript.isEmpty {
            let isFinal = (result.is_final ?? false) || (result.speech_final ?? false) || (result.from_finalize ?? false)
            return .transcript(text: transcript, isFinal: isFinal)
        }

        if result.type == "Error", let description = result.errorDescription {
            return .errorMessage(description)
        }

        return nil
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
