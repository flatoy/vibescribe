import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var statusMessage = "Idle"
    @Published var overlayPulseID = UUID()

    var hotkey = Hotkey.pushToTalkDefault

    init() {}
}
