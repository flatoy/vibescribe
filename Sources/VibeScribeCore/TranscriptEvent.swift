import Foundation

struct TranscriptEvent: Sendable {
    let text: String
    let isFinal: Bool
    let isSpeechFinal: Bool
    let receivedAt: Date
}
