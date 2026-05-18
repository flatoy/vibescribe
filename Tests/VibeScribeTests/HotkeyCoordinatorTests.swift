import Foundation
@testable import VibeScribeCore

@MainActor
func runHotkeyCoordinatorTests(_ t: TestHarness) {
    func makeCoordinator() -> (HotkeyCoordinator, ManualHotkeyScheduler, () -> [HotkeyIntent]) {
        let scheduler = ManualHotkeyScheduler()
        let coordinator = HotkeyCoordinator(scheduler: scheduler)
        var intents: [HotkeyIntent] = []
        coordinator.onIntent = { intents.append($0) }
        return (coordinator, scheduler, { intents })
    }

    t.run("push-to-talk hold emits start then stop after release") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        t.expectEqual(intents(), [])
        s.advance(by: 0.05)
        t.expectEqual(intents(), [.startRecording])
        c.primaryUp(at: 1.0)
        t.expectEqual(intents(), [.startRecording])
        s.advance(by: 0.2)
        t.expectEqual(intents(), [.startRecording, .stopRecording])
    }

    t.run("tap latches; second tap stops") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        s.advance(by: 0.05)
        t.expectEqual(intents(), [.startRecording])
        c.primaryUp(at: 0.15)
        t.expectEqual(intents(), [.startRecording])

        c.primaryDown(at: 5.0)
        s.advance(by: 0.05)
        t.expectEqual(intents(), [.startRecording])
        c.primaryUp(at: 5.1)
        s.advance(by: 0.2)
        t.expectEqual(intents(), [.startRecording, .stopRecording])
    }

    t.run("very fast tap during debounce still starts and latches") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        c.primaryUp(at: 0.03)
        t.expectEqual(intents(), [.startRecording])
        s.advance(by: 0.5)
        t.expectEqual(intents(), [.startRecording])

        c.primaryDown(at: 5.0)
        c.primaryUp(at: 5.1)
        s.advance(by: 0.2)
        t.expectEqual(intents(), [.startRecording, .stopRecording])
    }

    t.run("combo during debounce suppresses start; only picker fires") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        c.comboTriggered()
        s.advance(by: 1.0)
        t.expectEqual(intents(), [.openLanguagePicker])
    }

    t.run("combo while recording cancels then opens picker") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        s.advance(by: 0.05)
        t.expectEqual(intents(), [.startRecording])
        c.comboTriggered()
        t.expectEqual(intents(), [.startRecording, .cancelRecording, .openLanguagePicker])
    }

    t.run("combo while latched cancels then opens picker") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        s.advance(by: 0.05)
        c.primaryUp(at: 0.15)
        t.expectEqual(intents(), [.startRecording])
        c.comboTriggered()
        t.expectEqual(intents(), [.startRecording, .cancelRecording, .openLanguagePicker])
    }

    t.run("combo while idle just opens picker") {
        let (c, _, intents) = makeCoordinator()
        c.comboTriggered()
        t.expectEqual(intents(), [.openLanguagePicker])
    }

    t.run("repress during stopDelay cancels the pending stop") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        s.advance(by: 0.05)
        c.primaryUp(at: 1.0)
        s.advance(by: 0.1)
        t.expectEqual(intents(), [.startRecording])

        c.primaryDown(at: 1.1)
        s.advance(by: 1.0)
        t.expectEqual(intents(), [.startRecording])

        c.primaryUp(at: 3.0)
        s.advance(by: 0.2)
        t.expectEqual(intents(), [.startRecording, .stopRecording])
    }

    t.run("phantom primaryUp without prior primaryDown is ignored") {
        let (c, _, intents) = makeCoordinator()
        c.primaryUp(at: 1.0)
        t.expectEqual(intents(), [])
    }

    t.run("long hold while latched does nothing on release") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        s.advance(by: 0.05)
        c.primaryUp(at: 0.1)
        t.expectEqual(intents(), [.startRecording])

        c.primaryDown(at: 1.0)
        s.advance(by: 0.05)
        c.primaryUp(at: 3.0)
        s.advance(by: 0.5)
        t.expectEqual(intents(), [.startRecording])
    }
}
