import Combine
import CryptoKit
import Foundation
import Network

struct WhisperModelManifest: Decodable, Sendable {
    struct Source: Decodable, Sendable {
        let repo: String
        let revision: String
    }

    struct Entry: Decodable, Sendable {
        let source: String
        let sourcePath: String
        let path: String
        let size: Int64
        let sha256: String
    }

    let sources: [String: Source]
    let files: [Entry]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    static func load(from url: URL) throws -> Self {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !manifest.files.isEmpty,
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.allSatisfy({ entry in
                  entry.size > 0 && manifest.sources[entry.source] != nil &&
                  entry.sha256.count == 64 &&
                  entry.sha256.allSatisfy({ $0.isHexDigit }) &&
                  !entry.path.hasPrefix("/") &&
                  !entry.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
              }) else {
            throw WhisperModelDownloadError.invalidManifest
        }
        return manifest
    }

    func remoteURL(for entry: Entry) throws -> URL {
        guard let source = sources[entry.source] else {
            throw WhisperModelDownloadError.invalidManifest
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(source.repo)/resolve/\(source.revision)/\(entry.sourcePath)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        guard let url = components.url else {
            throw WhisperModelDownloadError.invalidManifest
        }
        return url
    }

    func localURL(for entry: Entry, in folder: URL) -> URL {
        folder.appendingPathComponent(entry.path)
    }
}

enum WhisperModelDownloadError: LocalizedError {
    case invalidManifest
    case serverResponse(String, Int)
    case invalidFile(String)
    case transferFailed(String, String)
    case offline(String)
    case notEnoughSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "The app's speech model manifest is invalid. Reinstall VibeScribe."
        case .serverResponse(let file, let status):
            return "Could not download \(file): server returned HTTP \(status)."
        case .invalidFile(let file):
            return "The downloaded \(file) did not pass verification."
        case .transferFailed(let file, let reason):
            return "Could not download \(file): \(reason)"
        case .offline(let reason):
            return reason
        case .notEnoughSpace(let needed, let available):
            let formatter = ByteCountFormatter()
            return "Not enough disk space. The model needs about \(formatter.string(fromByteCount: needed)) more; "
                + "\(formatter.string(fromByteCount: available)) is available."
        }
    }
}

enum WhisperModelFileVerification {
    static func isValid(_ url: URL, for entry: WhisperModelManifest.Entry) -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == Int(entry.size) else { return false }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return checksum == entry.sha256.lowercased()
        } catch {
            return false
        }
    }
}

private final class WhisperFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let stagingURL: URL
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var task: URLSessionDownloadTask?
    private var savedFile = false
    private var downloadError: Error?

    init(stagingURL: URL, onProgress: @Sendable @escaping (Int64) -> Void) {
        self.stagingURL = stagingURL
        self.onProgress = onProgress
    }

    func download(_ request: URLRequest) async throws -> URLResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                lock.lock()
                self.continuation = continuation
                self.task = task
                lock.unlock()
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: stagingURL)
            lock.lock()
            savedFile = true
            lock.unlock()
        } catch {
            lock.lock()
            downloadError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result: Result<URLResponse, Error>
        if let error {
            result = .failure(error)
        } else if let downloadError {
            result = .failure(downloadError)
        } else if !savedFile || task.response == nil {
            result = .failure(WhisperModelDownloadError.invalidFile(stagingURL.lastPathComponent))
        } else {
            result = .success(task.response!)
        }
        lock.unlock()
        continuation?.resume(with: result)
    }
}

actor WhisperModelDownloader {
    struct Inspection: Sendable {
        let completedBytes: Int64
        let missing: [WhisperModelManifest.Entry]
    }

    private let manifest: WhisperModelManifest
    private let folder: URL

    init(manifest: WhisperModelManifest, folder: URL) {
        self.manifest = manifest
        self.folder = folder
    }

    func inspect() -> Inspection {
        var completedBytes: Int64 = 0
        var missing: [WhisperModelManifest.Entry] = []
        for entry in manifest.files {
            let destination = manifest.localURL(for: entry, in: folder)
            if WhisperModelFileVerification.isValid(destination, for: entry) {
                completedBytes += entry.size
            } else {
                missing.append(entry)
            }
        }
        return Inspection(completedBytes: completedBytes, missing: missing)
    }

    func downloadMissing(
        _ inspection: Inspection,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        let totalBytes = manifest.totalBytes
        var completedBytes = inspection.completedBytes
        onProgress(completedBytes, totalBytes)

        for entry in inspection.missing {
            try Task.checkCancellation()
            let source = try manifest.remoteURL(for: entry)
            let destination = manifest.localURL(for: entry, in: folder)
            var request = URLRequest(url: source)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            var lastError: Error?

            for attempt in 1...3 {
                try Task.checkCancellation()
                let baseBytes = completedBytes
                let staging = folder.appendingPathComponent(".download-\(UUID().uuidString)")
                let download = WhisperFileDownload(stagingURL: staging) { received in
                    onProgress(baseBytes + min(max(received, 0), entry.size), totalBytes)
                }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let response = try await download.download(request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        throw WhisperModelDownloadError.serverResponse(entry.path, status)
                    }
                    guard WhisperModelFileVerification.isValid(staging, for: entry) else {
                        throw WhisperModelDownloadError.invalidFile(entry.path)
                    }
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: staging, to: destination)
                    completedBytes += entry.size
                    onProgress(completedBytes, totalBytes)
                    lastError = nil
                    break
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    lastError = error
                    onProgress(completedBytes, totalBytes)
                    if attempt < 3 {
                        try await Task.sleep(for: .seconds(attempt))
                    }
                }
            }
            if let lastError {
                if let downloadError = lastError as? WhisperModelDownloadError {
                    throw downloadError
                }
                if let urlError = lastError as? URLError, Self.isConnectivityError(urlError) {
                    throw WhisperModelDownloadError.offline(urlError.localizedDescription)
                }
                throw WhisperModelDownloadError.transferFailed(entry.path, lastError.localizedDescription)
            }
        }
    }
}

extension WhisperModelDownloader {
    static func isConnectivityError(_ error: URLError) -> Bool {
        [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
        ].contains(error.code)
    }
}

@MainActor
final class WhisperModelSetup: ObservableObject {
    enum State: Equatable {
        case checking
        /// Nothing is downloading. `completed` bytes are already on disk.
        case notDownloaded(Int64, Int64)
        case downloading(Int64, Int64)
        case paused(Int64, Int64)
        /// The connection dropped. Resumes on its own when the network returns.
        case interrupted(Int64, Int64, String)
        case preparing
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .checking
    /// Recent download speed, used for the time estimate.
    @Published private(set) var bytesPerSecond: Double?
    var onNeedsAttention: (() -> Void)?
    /// Loads the model after download. `nil` for models that are only downloaded.
    var prepareModel: (@MainActor () async throws -> Void)?

    let modelID: SpeechModelID
    let modelFolder: URL
    private let manifestURL: URL
    private let logger: Logger
    private var task: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var speedSamples: [(time: TimeInterval, bytes: Int64)] = []

    var isReady: Bool { state == .ready }

    /// Whether verification, download or preparation is actually in progress.
    var isRunning: Bool { task != nil }

    /// Fraction of the download that is on disk, when known.
    var progress: Double? {
        switch state {
        case .notDownloaded(let completed, let total), .downloading(let completed, let total),
             .paused(let completed, let total), .interrupted(let completed, let total, _):
            return total > 0 ? Double(completed) / Double(total) : nil
        case .preparing, .ready: return 1
        case .checking, .failed: return nil
        }
    }

    var secondsRemaining: TimeInterval? {
        guard case .downloading(let completed, let total) = state,
              let speed = bytesPerSecond, speed > 0 else { return nil }
        return Double(total - completed) / speed
    }

    var totalBytes: Int64? {
        (try? WhisperModelManifest.load(from: manifestURL))?.totalBytes
    }

    init(
        modelID: SpeechModelID = .largeV3,
        manifestURL: URL,
        modelFolder: URL,
        logger: Logger,
        prepareModel: (@MainActor () async throws -> Void)?
    ) {
        self.modelID = modelID
        self.manifestURL = manifestURL
        self.modelFolder = modelFolder
        self.logger = logger
        self.prepareModel = prepareModel
    }

    /// Verifies, downloads what is missing, then prepares the model if needed.
    func start() {
        guard task == nil else { return }
        stopWatchingNetwork()
        state = .checking
        bytesPerSecond = nil
        speedSamples = []
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                let manifest = try WhisperModelManifest.load(from: self.manifestURL)
                let downloader = WhisperModelDownloader(manifest: manifest, folder: self.modelFolder)
                let inspection = await downloader.inspect()
                try Task.checkCancellation()
                if !inspection.missing.isEmpty {
                    try self.checkFreeSpace(needed: manifest.totalBytes - inspection.completedBytes)
                    self.state = .downloading(inspection.completedBytes, manifest.totalBytes)
                    self.logger.append("Downloading \(self.modelID.shortName) speech model.")
                    self.onNeedsAttention?()
                    try await downloader.downloadMissing(inspection) { [weak self] completed, total in
                        Task { @MainActor [weak self] in
                            self?.recordProgress(completed, total)
                        }
                    }
                    self.logger.append("Speech model \(self.modelID.shortName) downloaded and verified.")
                } else {
                    self.logger.append("Cached speech model \(self.modelID.shortName) verified.")
                }
                try Task.checkCancellation()
                self.bytesPerSecond = nil
                if let prepareModel = self.prepareModel {
                    self.state = .preparing
                    try await prepareModel()
                }
                self.state = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.bytesPerSecond = nil
                if case WhisperModelDownloadError.offline(let reason) = error {
                    let (completed, total) = self.lastKnownBytes()
                    self.state = .interrupted(completed, total, reason)
                    self.logger.append("Speech model download paused: \(reason)", level: .warning)
                    self.watchNetwork()
                } else {
                    self.state = .failed(error.localizedDescription)
                    self.logger.append("Speech model setup failed: \(error.localizedDescription)", level: .error)
                }
                self.onNeedsAttention?()
            }
        }
    }

    func pause() {
        guard task != nil else { return }
        let (completed, total) = lastKnownBytes()
        task?.cancel()
        task = nil
        bytesPerSecond = nil
        state = .paused(completed, total)
        logger.append("Speech model download paused.")
    }

    /// Stops a download without resuming automatically. Partial files are kept.
    func cancel() {
        let (completed, total) = lastKnownBytes()
        task?.cancel()
        task = nil
        stopWatchingNetwork()
        bytesPerSecond = nil
        state = .notDownloaded(completed, total)
    }

    /// Cheap check for models that are not in use: looks for the files without hashing them.
    func refreshAvailability() {
        guard task == nil else { return }
        let total = totalBytes ?? 0
        state = WhisperModelLocator.isComplete(modelFolder) ? .ready : .notDownloaded(partialBytes(), total)
    }

    func delete() throws {
        cancel()
        if FileManager.default.fileExists(atPath: modelFolder.path) {
            try FileManager.default.removeItem(at: modelFolder)
        }
        state = .notDownloaded(0, totalBytes ?? 0)
        logger.append("Deleted speech model \(modelID.shortName).")
    }

    /// For previews and README screenshots.
    func simulate(_ state: State, bytesPerSecond: Double? = nil) {
        self.state = state
        self.bytesPerSecond = bytesPerSecond
    }

    private func recordProgress(_ completed: Int64, _ total: Int64) {
        guard case .downloading(let displayed, _) = state else { return }
        let now = ProcessInfo.processInfo.systemUptime
        speedSamples.append((now, completed))
        speedSamples.removeAll { now - $0.time > 8 }
        if let first = speedSamples.first, now - first.time > 1, completed > first.bytes {
            bytesPerSecond = Double(completed - first.bytes) / (now - first.time)
        }
        if abs(completed - displayed) >= 1_000_000 || completed == total || completed < displayed {
            state = .downloading(completed, total)
        }
    }

    private func lastKnownBytes() -> (Int64, Int64) {
        switch state {
        case .downloading(let completed, let total), .paused(let completed, let total),
             .notDownloaded(let completed, let total), .interrupted(let completed, let total, _):
            return (completed, total)
        default:
            return (partialBytes(), totalBytes ?? 0)
        }
    }

    private func partialBytes() -> Int64 {
        guard let manifest = try? WhisperModelManifest.load(from: manifestURL) else { return 0 }
        return manifest.files.reduce(0) { sum, entry in
            let url = manifest.localURL(for: entry, in: modelFolder)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + (Int64(size) == entry.size ? entry.size : 0)
        }
    }

    private func checkFreeSpace(needed: Int64) throws {
        var probe = modelFolder
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return }
        // Leave room for the staging copy of the largest file.
        if available < needed + 50_000_000 {
            throw WhisperModelDownloadError.notEnoughSpace(needed: needed, available: available)
        }
    }

    private func watchNetwork() {
        stopWatchingNetwork()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                // The first update arrives immediately; give a flaky connection a moment.
                try? await Task.sleep(for: .seconds(3))
                guard let self, case .interrupted = self.state else { return }
                self.logger.append("Connection is back. Resuming the speech model download.")
                self.start()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        pathMonitor = monitor
    }

    private func stopWatchingNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }
}
