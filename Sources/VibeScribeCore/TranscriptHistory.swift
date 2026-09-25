import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let text: String
    let languageCode: String?
    let duration: TimeInterval
    /// The app the text was sent to.
    let appName: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        text: String,
        languageCode: String?,
        duration: TimeInterval,
        appName: String?
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.languageCode = languageCode
        self.duration = duration
        self.appName = appName
    }
}

/// Past transcripts, stored only on this Mac.
@MainActor
final class TranscriptHistory: ObservableObject {
    /// Newest first.
    @Published private(set) var entries: [HistoryEntry] = []
    /// The most recent transcript, kept in memory even when history is off.
    @Published private(set) var last: HistoryEntry?

    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    static func defaultURL() -> URL {
        WhisperModelLocator.supportFolder().appendingPathComponent("History.json")
    }

    func add(_ entry: HistoryEntry, retention: HistoryRetention) {
        last = entry
        guard retention != .off else { return }
        entries.insert(entry, at: 0)
        prune(retention: retention)
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    func prune(retention: HistoryRetention, now: Date = Date()) {
        guard let interval = retention.interval else { return }
        let before = entries.count
        entries.removeAll { now.timeIntervalSince($0.date) > interval }
        if entries.count != before { save() }
    }

    func search(_ query: String) -> [HistoryEntry] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return entries }
        return entries.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed)
                || ($0.appName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    /// For previews and README screenshots.
    func simulate(_ entries: [HistoryEntry]) {
        self.entries = entries
        last = entries.first
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        last = entries.first
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(entries).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // History is a convenience; a failed write must not interrupt dictation.
        }
    }
}
