import Foundation

@MainActor
final class Logger: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []

    init() {}

    func append(_ message: String, level: LogLevel = .info) {
        entries.append(LogEntry(timestamp: Date(), level: level, message: message))
    }

    func clear() {
        entries.removeAll()
    }
}
