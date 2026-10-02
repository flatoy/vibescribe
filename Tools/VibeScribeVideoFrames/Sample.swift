// App state for the film, built like Sample in Tools/VibeScribeScreenshots/main.swift but with the
// film's data (video/spec.json): the four transcripts of the day, the vocabulary, the pinned languages.

import AppKit
import Carbon
import SwiftUI
@testable import VibeScribeCore

/// A window frame around a view, as macOS would draw it (same as Tools/VibeScribeScreenshots).
struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0xFF5F57))
            Circle().fill(Color(hex: 0xFEBC2E))
            Circle().fill(Color(hex: 0x28C840))
        }
        .frame(width: 52, height: 12)
    }
}

struct WindowFrame<Content: View>: View {
    var size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) { TrafficLights().padding(.leading, 20).padding(.top, 14) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: Color(hex: 0x28144A).opacity(0.45), radius: 30, y: 24)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
    }
}

enum Film {
    static let spanish = WhisperLanguage(rawValue: "es")!
    static let french = WhisperLanguage(rawValue: "fr")!
    static let japanese = WhisperLanguage(rawValue: "ja")!
    static let german = WhisperLanguage(rawValue: "de")!

    static let pinned: [WhisperLanguage] = [.automatic, .english, spanish]
    static let vocabulary = "Priya Raman, Lena Fischer, Trailhead, Kubernetes"

    struct Transcript {
        var hour: Int
        var minute: Int
        var app: String
        var language: String
        var duration: TimeInterval
        var text: String
    }

    /// Newest first, all today. The texts are what the app's own engine (WhisperKit, large-v3, the
    /// film's vocabulary) transcribed from the film's voice clips (video/build/audio/clips.json ->
    /// app_engine), and the durations are each scene's re-timed recording (stop - start), so History
    /// shows exactly what the film pasted.
    static let transcripts: [Transcript] = [
        Transcript(hour: 19, minute: 48, app: "Notes", language: "en", duration: 4.47,
                   text: "Call the landlord about the heating. Oh, and buy oat milk."),
        Transcript(hour: 16, minute: 5, app: "Chat", language: "de", duration: 3.82,
                   text: "Klingt gut, ich bin dabei, komme aber ein bisschen später."),
        Transcript(hour: 11, minute: 47, app: "Terminal", language: "en", duration: 7.1,
                   text: "Uploads keep failing on bad Wi-Fi, add retries with back-off, and write a test for the offline case."),
        Transcript(hour: 9, minute: 12, app: "Inbox", language: "en", duration: 6.4,
                   text: "Hi Priya, looks great. Could we do the budget review first so we end on the fun stuff? Thanks."),
    ]
}

@MainActor
func filmPreferences(recent: [WhisperLanguage] = [Film.french, Film.japanese, .english]) -> Preferences {
    let defaults = UserDefaults(suiteName: "VibeScribeVideoFrames.\(UUID().uuidString)")!
    let preferences = Preferences(defaults: defaults)
    preferences.pinnedLanguages = Film.pinned
    // select() puts each language first in Recent, so the last one chosen is the current language.
    for language in recent { preferences.select(language) }
    preferences.vocabulary = Film.vocabulary
    preferences.historyRetention = .month
    preferences.pushToTalkHotkey = .pushToTalkDefault
    preferences.triggerMode = .holdOrTap
    return preferences
}

@MainActor
struct FilmContext {
    let context: AppContext
    let preferences: Preferences
    let history: TranscriptHistory
    let models: SpeechModelLibrary

    init(preferences: Preferences = filmPreferences()) {
        self.preferences = preferences
        let logger = Logger()
        let permissions = Permissions()
        permissions.simulate(microphone: .authorized, inputMonitoring: .authorized, accessibility: .authorized)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VibeScribeVideoFrames")
        let client = WhisperKitClient(modelFolder: temp) { _, _ in }
        models = SpeechModelLibrary(
            preferences: preferences,
            logger: logger,
            client: client,
            folder: { temp.appendingPathComponent($0.rawValue) }
        )
        models.setup(for: .largeV3).simulate(.ready)
        models.setup(for: .largeV3Turbo).simulate(.notDownloaded(0, 648_432_373))
        history = TranscriptHistory(fileURL: nil)
        let now = Date()
        let calendar = Calendar.current
        history.simulate(Film.transcripts.map { item in
            HistoryEntry(
                date: calendar.date(bySettingHour: item.hour, minute: item.minute, second: 0, of: now)!,
                text: item.text,
                languageCode: item.language,
                duration: item.duration,
                appName: item.app
            )
        })
        let microphones = MicrophoneMonitor()
        microphones.level.simulate(0.52)
        context = AppContext(
            preferences: preferences,
            permissions: permissions,
            models: models,
            history: history,
            logger: logger,
            status: AppStatus(simulated: .ready),
            microphones: microphones,
            loginItem: LoginItem(simulatedEnabled: true),
            recorder: HotkeyRecorder(),
            output: TextOutput(preferences: preferences, logger: logger)
        )
    }
}

/// Right ⌘ as a modifier-only shortcut, built the way HotkeyRecorder builds a recorded modifier key.
let rightCommandHotkey = Hotkey(trigger: .modifierOnly, keyCode: UInt16(kVK_RightCommand), modifiers: [.command])

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type, where predicate: (T) -> Bool = { _ in true }) -> T? {
        for subview in subviews {
            if let match = subview as? T, predicate(match) { return match }
            if let match = subview.firstDescendant(of: type, where: predicate) { return match }
        }
        return nil
    }
}

/// Where the caret would sit at the end of a text view's text, in canvas points (top-left origin).
@MainActor
func caretRect(of textView: NSTextView, in host: Host) -> CGRect? {
    guard let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
    let length = (textView.string as NSString).length
    layout.ensureLayout(for: container)
    var rect: NSRect
    if length == 0 {
        rect = layout.extraLineFragmentRect
        if rect.isEmpty { rect = NSRect(x: 0, y: 0, width: 1, height: textView.font?.boundingRectForFont.height ?? 16) }
        rect.size.width = 1
    } else {
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: length - 1, length: 1), actualCharacterRange: nil)
        let glyphRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let lineRect = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        rect = NSRect(x: glyphRect.maxX, y: lineRect.minY, width: 1, height: lineRect.height)
    }
    rect.origin.x += textView.textContainerOrigin.x
    rect.origin.y += textView.textContainerOrigin.y
    let inWindow = textView.convert(rect, to: nil)
    let inHost = host.hosting.convert(inWindow, from: nil)
    // NSHostingView is flipped (top-left origin), like the canvas.
    if host.hosting.isFlipped { return inHost }
    return CGRect(x: inHost.minX, y: host.size.height - inHost.maxY, width: inHost.width, height: inHost.height)
}
