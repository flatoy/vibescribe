import AppKit
import Carbon
import Foundation
@testable import VibeScribeCore

@MainActor
private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "VibeScribeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@MainActor
func runSettingsPreferencesTests(_ t: TestHarness) {
    t.run("new settings have sensible defaults") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            t.expectEqual(prefs.pinnedLanguages, [.automatic, .english])
            t.expectEqual(prefs.pushToTalkHotkey, .pushToTalkDefault)
            t.expectEqual(prefs.triggerMode, .holdOrTap)
            t.expectEqual(prefs.outputMode, .paste)
            t.expect(prefs.restoreClipboard)
            t.expect(prefs.playSounds)
            t.expectEqual(prefs.historyRetention, .month)
            t.expectEqual(prefs.speechModel, .largeV3)
            t.expect(!prefs.hasCompletedOnboarding)
            t.expectNil(prefs.microphoneUID)
        }
    }

    t.run("settings persist across instances") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            let hotkey = Hotkey(trigger: .keyCombo, keyCode: UInt16(kVK_ANSI_D), modifiers: [.command, .shift])
            prefs.pushToTalkHotkey = hotkey
            prefs.triggerMode = .tapOnly
            prefs.outputMode = .clipboard
            prefs.microphoneUID = "usb-mic"
            prefs.vocabulary = "VibeScribe, WhisperKit"
            prefs.historyRetention = .week
            prefs.speechModel = .largeV3Turbo
            prefs.hasCompletedOnboarding = true
            let restored = Preferences(defaults: defaults)
            t.expectEqual(restored.pushToTalkHotkey, hotkey)
            t.expectEqual(restored.triggerMode, .tapOnly)
            t.expectEqual(restored.outputMode, .clipboard)
            t.expectEqual(restored.microphoneUID, "usb-mic")
            t.expectEqual(restored.vocabularyWords, ["VibeScribe", "WhisperKit"])
            t.expectEqual(restored.historyRetention, .week)
            t.expectEqual(restored.speechModel, .largeV3Turbo)
            t.expect(restored.hasCompletedOnboarding)
        }
    }

    t.run("choosing a language records it as recent, newest first, at most three") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            for code in ["fr", "de", "sv", "fr"] {
                prefs.select(WhisperLanguage(rawValue: code)!)
            }
            t.expectEqual(prefs.language.rawValue, "fr")
            t.expectEqual(prefs.recentLanguages.map(\.rawValue), ["fr", "sv", "de"])
        }
    }

    t.run("pinning is limited to three and unpinning frees a slot") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            let norwegian = WhisperLanguage(rawValue: "no")!
            let french = WhisperLanguage(rawValue: "fr")!
            t.expect(prefs.togglePin(norwegian))
            t.expect(!prefs.togglePin(french))
            t.expect(prefs.togglePin(.english))
            t.expect(prefs.togglePin(french))
            t.expectEqual(prefs.pinnedLanguages, [.automatic, norwegian, french])
        }
    }

    t.run("vocabulary splits on commas and new lines") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.vocabulary = " Flåtøy,  Kubernetes\nSwiftUI,, "
            t.expectEqual(prefs.vocabularyWords, ["Flåtøy", "Kubernetes", "SwiftUI"])
        }
    }
}

@MainActor
func runHotkeyTests(_ t: TestHarness) {
    t.run("hotkeys describe themselves as keycaps") {
        t.expectEqual(Hotkey.pushToTalkDefault.keycaps, ["Right ⌥"])
        t.expectEqual(Hotkey.languagePickerDefault.keycaps, ["⌥", "⇧"])
        t.expectEqual(Hotkey.escape.keycaps, ["esc"])
        let combo = Hotkey(trigger: .keyCombo, keyCode: UInt16(kVK_Space), modifiers: [.control, .command])
        t.expectEqual(combo.keycaps, ["⌃", "⌘", "Space"])
    }

    t.run("hotkeys round-trip through JSON") {
        let hotkey = Hotkey(trigger: .modifierOnly, keyCode: UInt16(kVK_RightCommand), modifiers: [.command])
        let data = try JSONEncoder().encode(hotkey)
        t.expectEqual(try JSONDecoder().decode(Hotkey.self, from: data), hotkey)
    }

    t.run("hotkeys ignore modifiers outside the comparison mask") {
        let hotkey = Hotkey(trigger: .modifierCombo, keyCode: 0, modifiers: [.option, .shift, .capsLock, .function])
        t.expectEqual(hotkey.modifiers, [.option, .shift])
    }
}

@MainActor
func runLanguagePickerModelTests(_ t: TestHarness) {
    let norwegian = WhisperLanguage(rawValue: "no")!
    let swedish = WhisperLanguage(rawValue: "sv")!

    t.run("empty search lists pinned, then recent, then everything else once") {
        let rows = LanguagePickerModel.compute(query: "", pinned: [.automatic, norwegian], recent: [norwegian, swedish])
        t.expectEqual(rows.prefix(3).map(\.language), [.automatic, norwegian, swedish])
        t.expectEqual(rows.prefix(3).map(\.section), [.pinned, .pinned, .recent])
        t.expectEqual(rows.prefix(2).map(\.shortcut), [1, 2])
        t.expectEqual(rows.count, WhisperLanguage.allCases.count)
        t.expectEqual(Set(rows.map(\.language)).count, rows.count)
    }

    t.run("search finds a language by its native name") {
        let rows = LanguagePickerModel.compute(query: "norsk", pinned: [], recent: [])
        t.expect(rows.contains { $0.language == norwegian && !$0.nativeMatches.isEmpty })
    }

    t.run("search ranks the closest name first and marks matched letters") {
        let rows = LanguagePickerModel.compute(query: "nor", pinned: [], recent: [])
        let first = try t.require(rows.first)
        t.expectEqual(first.language, norwegian)
        t.expectEqual(first.nameMatches, [0, 1, 2])
    }

    t.run("fuzzy match requires letters in order") {
        t.expect(LanguagePickerModel.fuzzyMatch(query: "gmn", in: "German") != nil)
        t.expectNil(LanguagePickerModel.fuzzyMatch(query: "nmg", in: "German"))
    }

    t.run("pinned shortcut chooses the pinned language") {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            let model = LanguagePickerModel(preferences: prefs)
            var chosen: WhisperLanguage?
            model.onCommit = { chosen = $0 }
            model.commitPinned(2)
            t.expectEqual(chosen, .english)
        }
    }

    t.run("every language has a badge and automatic has a native hint") {
        t.expectEqual(WhisperLanguage.automatic.badge, "AUTO")
        t.expectEqual(norwegian.badge, "NO")
        t.expectEqual(WhisperLanguage.automatic.nativeName, "detect")
        t.expectNil(WhisperLanguage.english.nativeName)
    }
}

@MainActor
func runHistoryTests(_ t: TestHarness) {
    func entry(_ text: String, daysAgo: Double = 0, app: String? = "Notes") -> HistoryEntry {
        HistoryEntry(
            date: Date().addingTimeInterval(-daysAgo * 86_400),
            text: text,
            languageCode: "en",
            duration: 2,
            appName: app
        )
    }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VibeScribeHistory-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }

    t.run("history keeps newest first and persists to disk") {
        let url = folder.appendingPathComponent("History.json")
        let history = TranscriptHistory(fileURL: url)
        history.add(entry("first"), retention: .month)
        history.add(entry("second"), retention: .month)
        t.expectEqual(history.entries.map(\.text), ["second", "first"])
        let reloaded = TranscriptHistory(fileURL: url)
        t.expectEqual(reloaded.entries.map(\.text), ["second", "first"])
        t.expectEqual(reloaded.last?.text, "second")
    }

    t.run("history off keeps only the last transcript in memory") {
        let history = TranscriptHistory(fileURL: nil)
        history.add(entry("secret"), retention: .off)
        t.expect(history.entries.isEmpty)
        t.expectEqual(history.last?.text, "secret")
    }

    t.run("pruning drops entries older than the retention period") {
        let history = TranscriptHistory(fileURL: nil)
        history.simulate([entry("today"), entry("last week", daysAgo: 6), entry("old", daysAgo: 40)])
        history.prune(retention: .month)
        t.expectEqual(history.entries.map(\.text), ["today", "last week"])
        history.prune(retention: .day)
        t.expectEqual(history.entries.map(\.text), ["today"])
    }

    t.run("search matches text and target app") {
        let history = TranscriptHistory(fileURL: nil)
        history.simulate([entry("Refactor the session", app: "Terminal"), entry("Takk for i dag", app: "Messages")])
        t.expectEqual(history.search("takk").map(\.text), ["Takk for i dag"])
        t.expectEqual(history.search("terminal").map(\.text), ["Refactor the session"])
        t.expectEqual(history.search("  ").count, 2)
    }
}

@MainActor
func runAppStatusTests(_ t: TestHarness) {
    t.run("recording wins over setup and issues") {
        let phase = AppStatus.phase(session: .recording, model: .preparing, issues: [.pastingOff], shortcutPaused: false)
        t.expectEqual(phase, .recording)
    }

    t.run("downloading shows progress") {
        let phase = AppStatus.phase(session: .idle, model: .downloading(50, 200), issues: [], shortcutPaused: false)
        t.expectEqual(phase, .settingUp(progress: 0.25))
    }

    t.run("a lost permission needs attention once the model is ready") {
        let issues = AppStatus.issues(
            model: .ready,
            microphone: .authorized,
            inputMonitoring: .authorized,
            accessibility: .denied,
            outputMode: .paste
        )
        t.expectEqual(issues, [.pastingOff])
        t.expectEqual(AppStatus.phase(session: .idle, model: .ready, issues: issues, shortcutPaused: false), .attention(.pastingOff))
    }

    t.run("clipboard-only mode does not need Accessibility") {
        let issues = AppStatus.issues(
            model: .ready,
            microphone: .authorized,
            inputMonitoring: .authorized,
            accessibility: .denied,
            outputMode: .clipboard
        )
        t.expect(issues.isEmpty)
    }

    t.run("a failed model comes first and paused shortcut shows when all is well") {
        let issues = AppStatus.issues(
            model: .failed("disk"),
            microphone: .denied,
            inputMonitoring: .authorized,
            accessibility: .authorized,
            outputMode: .paste
        )
        t.expectEqual(issues, [.modelFailed("disk"), .microphoneOff])
        t.expectEqual(AppStatus.phase(session: .idle, model: .ready, issues: [], shortcutPaused: true), .shortcutPaused)
    }
}

@MainActor
func runFormatTests(_ t: TestHarness) {
    t.run("durations and time estimates read naturally") {
        t.expectEqual(Format.duration(7.4), "0:07")
        t.expectEqual(Format.duration(62), "1:02")
        t.expectEqual(Format.timeRemaining(20), "less than a minute left")
        t.expectEqual(Format.timeRemaining(70), "about 1 min left")
        t.expectEqual(Format.timeRemaining(300), "about 5 min left")
        t.expectNil(Format.timeRemaining(nil))
    }
}

@MainActor
func runSpeechDetectorTests(_ t: TestHarness) {
    let rate = 16_000.0
    func noise(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * rate)).map { _ in Float.random(in: -amplitude...amplitude) }
    }
    func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    t.run("quiet room noise is not speech") {
        t.expect(!SpeechDetector.containsSpeech(noise(3, amplitude: 0.002), sampleRate: rate))
    }

    t.run("a key click is too short to be speech") {
        let samples = noise(1, amplitude: 0.002) + tone(0.05, amplitude: 0.5) + noise(2, amplitude: 0.002)
        t.expect(!SpeechDetector.containsSpeech(samples, sampleRate: rate))
    }

    t.run("voice well above the noise floor is speech") {
        let samples = noise(1, amplitude: 0.002) + tone(0.8, amplitude: 0.1) + noise(1, amplitude: 0.002)
        t.expect(SpeechDetector.containsSpeech(samples, sampleRate: rate))
    }

    t.run("an empty recording is not speech") {
        t.expect(!SpeechDetector.containsSpeech([], sampleRate: rate))
    }
}

@MainActor
func runPermissionHelperTests(_ t: TestHarness) {
    _ = NSApplication.shared
    t.run("helper sits below the System Settings window, inside the screen") {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSRect(x: screen.midX - 360, y: screen.midY, width: 720, height: 300)
        let frame = PermissionHelperController.placement(beside: window, size: PermissionHelperView.size)
        t.expect(frame.maxY <= window.minY, "Expected the card below the window")
        t.expect(screen.contains(frame), "Expected the card on screen")
    }

    t.run("helper overlaps the window's bottom edge when there is no room below") {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSRect(x: screen.minX + 100, y: screen.minY, width: 720, height: 500)
        let frame = PermissionHelperController.placement(beside: window, size: PermissionHelperView.size)
        t.expect(frame.minY >= screen.minY, "Expected the card above the bottom of the screen")
        t.expect(window.intersects(frame), "Expected the card to overlap the window")
    }
}
