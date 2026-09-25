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
        t.expectEqual(intents(), [.startRecording, .handsFree])

        c.primaryDown(at: 5.0)
        s.advance(by: 0.05)
        t.expectEqual(intents(), [.startRecording, .handsFree])
        c.primaryUp(at: 5.1)
        s.advance(by: 0.2)
        t.expectEqual(intents(), [.startRecording, .handsFree, .stopRecording])
    }

    t.run("very fast tap during debounce still starts and latches") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0.0)
        c.primaryUp(at: 0.03)
        t.expectEqual(intents(), [.startRecording, .handsFree])
        s.advance(by: 0.5)
        t.expectEqual(intents(), [.startRecording, .handsFree])

        c.primaryDown(at: 5.0)
        c.primaryUp(at: 5.1)
        s.advance(by: 0.2)
        t.expectEqual(intents(), [.startRecording, .handsFree, .stopRecording])
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
        t.expectEqual(intents(), [.startRecording, .handsFree])
        c.comboTriggered()
        t.expectEqual(intents(), [.startRecording, .handsFree, .cancelRecording, .openLanguagePicker])
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
        t.expectEqual(intents(), [.startRecording, .handsFree])

        c.primaryDown(at: 1.0)
        s.advance(by: 0.05)
        c.primaryUp(at: 3.0)
        s.advance(by: 0.5)
        t.expectEqual(intents(), [.startRecording, .handsFree])
    }

    t.run("reset clears a rejected tap so the next tap can start") {
        let (c, _, intents) = makeCoordinator()
        c.primaryDown(at: 0)
        c.primaryUp(at: 0.03)
        t.expectEqual(intents(), [.startRecording, .handsFree])
        c.reset()

        c.primaryDown(at: 1)
        c.primaryUp(at: 1.03)
        t.expectEqual(intents(), [.startRecording, .handsFree, .startRecording, .handsFree])
    }

    t.run("hold-only mode never latches on a tap") {
        let (c, s, intents) = makeCoordinator()
        c.mode = .holdOnly
        c.primaryDown(at: 0)
        s.advance(by: 0.05)
        c.primaryUp(at: 0.15)
        s.advance(by: 0.2)
        t.expectEqual(intents(), [.startRecording, .stopRecording])
    }

    t.run("hold-only mode ignores a tap shorter than the debounce") {
        let (c, s, intents) = makeCoordinator()
        c.mode = .holdOnly
        c.primaryDown(at: 0)
        c.primaryUp(at: 0.02)
        s.advance(by: 1)
        t.expectEqual(intents(), [])
    }

    t.run("tap-only mode toggles on each press and ignores releases") {
        let (c, s, intents) = makeCoordinator()
        c.mode = .tapOnly
        c.primaryDown(at: 0)
        s.advance(by: 0.05)
        c.primaryUp(at: 2)
        s.advance(by: 1)
        t.expectEqual(intents(), [.startRecording, .handsFree])
        c.primaryDown(at: 5)
        s.advance(by: 0)
        c.primaryUp(at: 5.1)
        t.expectEqual(intents(), [.startRecording, .handsFree, .stopRecording])
    }

    t.run("escape cancels a recording and is ignored when idle") {
        let (c, s, intents) = makeCoordinator()
        c.cancelRequested()
        t.expectEqual(intents(), [])
        c.primaryDown(at: 0)
        s.advance(by: 0.05)
        c.cancelRequested()
        t.expectEqual(intents(), [.startRecording, .cancelRecording])
        t.expect(!c.isRecording)
    }

    t.run("changing mode resets a latched recording state") {
        let (c, s, intents) = makeCoordinator()
        c.primaryDown(at: 0)
        s.advance(by: 0.05)
        c.primaryUp(at: 0.1)
        c.mode = .holdOnly
        t.expect(!c.isRecording)
        t.expectEqual(intents(), [.startRecording, .handsFree])
    }

    t.run("picker combo arriving before the dictation key press does not start hands-free") {
        let (c, s, intents) = makeCoordinator()
        // One flagsChanged event reaches the picker listener first, then push-to-talk.
        c.comboTriggered()
        c.primaryDown(at: 0)
        c.primaryUp(at: 0.1)
        s.advance(by: 1)
        t.expectEqual(intents(), [.openLanguagePicker])
    }

    t.run("dictation key works again after the picker combo is released") {
        let (c, s, intents) = makeCoordinator()
        c.comboTriggered()
        c.primaryDown(at: 0)
        c.comboReleased()
        c.primaryUp(at: 0.3)
        c.primaryDown(at: 2)
        s.advance(by: 0.05)
        t.expectEqual(intents(), [.openLanguagePicker, .startRecording])
    }

    t.run("a combo without the dictation key does not swallow the next press") {
        let (c, s, intents) = makeCoordinator()
        c.comboTriggered()
        c.comboReleased()
        c.primaryDown(at: 1)
        s.advance(by: 0.05)
        t.expectEqual(intents(), [.openLanguagePicker, .startRecording])
    }
}
