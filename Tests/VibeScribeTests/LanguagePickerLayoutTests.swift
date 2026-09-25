import AppKit
import SwiftUI
@testable import VibeScribeCore

@MainActor
func runLanguagePickerLayoutTests(_ t: TestHarness) {
    t.run("language picker keeps its list area while search changes") {
        _ = NSApplication.shared
        let suite = "VibeScribeTests.LanguagePicker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = LanguagePickerWindowController(
            preferences: Preferences(defaults: defaults),
            logger: Logger()
        )
        controller.show()
        defer { controller.hide(restoreFocus: false) }
        let panel = try t.require(
            NSApp.windows.first { $0.contentViewController is NSHostingController<LanguagePickerView> },
            "language picker panel did not open"
        )
        let hosting = try t.require(
            panel.contentViewController as? NSHostingController<LanguagePickerView>
        )
        let model = hosting.rootView.model

        @MainActor func expectFullHeight(_ state: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let height = panel.frame.height
            t.expect(height >= 300, "Picker collapsed to \(height) pt after \(state)")
        }

        expectFullHeight("opening")
        model.query = "english"
        t.expect(model.results.contains(.english))
        expectFullHeight("filtering")
        model.query = "englishx"
        t.expect(model.results.isEmpty)
        expectFullHeight("no matches")
        model.query = "english"
        t.expect(model.results.contains(.english))
        expectFullHeight("Backspace")
    }
}
