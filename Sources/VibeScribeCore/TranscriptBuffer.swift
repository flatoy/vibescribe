import Foundation

@MainActor
final class TranscriptBuffer: ObservableObject {
    @Published private(set) var last: String = ""
    @Published private(set) var final: String = ""

    private var segments: [String] = []

    init() {}

    func reset() {
        last = ""
        final = ""
        segments.removeAll()
    }

    func handle(_ text: String, isFinal: Bool) {
        last = text
        guard isFinal else { return }
        let trimmed = text.trimmed
        guard !trimmed.isEmpty else { return }
        if segments.last != trimmed {
            segments.append(trimmed)
            final = segments.joined(separator: " ")
        }
    }

    var effectiveText: String {
        let trimmedFinal = final.trimmed
        if !trimmedFinal.isEmpty { return trimmedFinal }
        return last.trimmed
    }
}
