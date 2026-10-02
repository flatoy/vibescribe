// The overlay pill: real OverlayPill renders, shimmer removal and the clean plate under the bars.

import AppKit
import SwiftUI
@testable import VibeScribeCore

enum PillState {
    case listening(handsFree: Bool, seconds: Int, keycaps: [String])
    case transcribing(badge: String?)
    case result(OverlayResult)

    var hasBars: Bool {
        switch self {
        case .listening, .transcribing: return true
        case .result(let result):
            switch result {
            case .noSpeech, .cancelled: return true
            default: return false
            }
        }
    }

    var hasShimmer: Bool {
        if case .transcribing = self { return true }
        return false
    }

    /// Live (listening) or thinking (transcribing) bars, which move every frame.
    var isAnimated: Bool {
        switch self {
        case .listening, .transcribing: return true
        case .result: return false
        }
    }
}

struct PillRender {
    /// Full canvas, before trimming.
    var bitmap: Bitmap
    /// The pill body (without its shadow) in canvas points.
    var pillRect: CGRect
    var scale: Int
    /// Where the 33×16 pt bars sit, in canvas points.
    var barsRect: CGRect { CGRect(origin: CGPoint(x: pillRect.minX + PillGeometry.barsOrigin.x, y: pillRect.minY + PillGeometry.barsOrigin.y), size: PillGeometry.barsSize) }
    var cleanPlated: Bool
    var title: String
    var meta: String?
}

enum PillCanvas {
    static let bleed: CGFloat = 40
    static let width: CGFloat = 640
    static var size: CGSize { CGSize(width: width, height: PillGeometry.height + bleed * 2) }
}

/// The view a pill sprite is made from: the real OverlayPill at the canvas' top-left plus the bleed.
private struct PillScene: View {
    @ObservedObject var model: OverlayModel
    var level: Float
    var reduceMotion: Bool

    var body: some View {
        OverlayPill(phase: model.phase, model: model, level: level)
            .measure("pill")
            .padding(PillCanvas.bleed)
            .environment(\._accessibilityReduceMotion, reduceMotion)
    }
}

@MainActor
func makeOverlayModel(_ state: PillState) -> (OverlayModel, Date?) {
    let meter = LevelMeter()
    let model = OverlayModel(level: meter)
    var startedAt: Date?
    switch state {
    case .listening(let handsFree, let seconds, let keycaps):
        model.shortcutKeycaps = keycaps
        // The timer is a TimelineView(.periodic(from: startedAt, by: 1)), so it shows whole seconds since
        // startedAt. Starting a little over N seconds ago makes it read N for the next ~0.9 s.
        let start = Date().addingTimeInterval(-Double(seconds) - 0.05)
        model.showListening(handsFree: handsFree, startedAt: start)
        startedAt = start
    case .transcribing(let badge):
        model.languageBadge = badge
        model.showTranscribing()
    case .result(let result):
        model.show(result, for: 3600)
    }
    return (model, startedAt)
}

/// Renders the real pill. Bars are frozen to their still shape (reduce motion) and then, when
/// `cleanPlate` is set, painted out; the shimmer is removed with the minimum of three captures.
@MainActor
func renderPill(_ state: PillState, scale: Int, cleanPlate: Bool = true) -> PillRender {
    for attempt in 0..<3 {
        let (model, startedAt) = makeOverlayModel(state)
        MeasureStore.shared.rects = [:]
        // Reduce motion only where the bars animate: it freezes live and thinking bars to the still
        // shape, but would also turn the flat bars of a "No speech heard" result into the still shape.
        let host = Host(PillScene(model: model, level: 0, reduceMotion: state.isAnimated), size: PillCanvas.size)
        host.wait(0.35)
        var captures = [host.capture(scale: CGFloat(scale))]
        if state.hasShimmer {
            // The band covers a third of each 1.6 s sweep; captures 0.55 s apart never all overlap it.
            for _ in 0..<3 {
                host.wait(0.55)
                captures.append(host.capture(scale: CGFloat(scale)))
            }
        }
        let rect = MeasureStore.shared.rects["pill"] ?? .zero
        host.close()
        if case .listening(_, let seconds, _) = state, let startedAt {
            // A capture that straddled the next whole second would show the wrong timer.
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= Double(seconds) + 0.95 {
                print("  retrying \(seconds) s pill (capture took \(String(format: "%.2f", elapsed - Double(seconds))) s)")
                continue
            }
        }
        guard rect.width > 0 else { fatalError("The pill wasn't measured.") }
        var bitmap = state.hasShimmer ? Bitmap.minimum(captures) : captures[0]
        var render = PillRender(bitmap: bitmap, pillRect: rect, scale: scale, cleanPlated: false,
                                title: pillTitle(state), meta: pillMeta(state))
        if cleanPlate, state.hasBars {
            bitmap.cleanPlate(barsPlateRect(render))
            render.bitmap = bitmap
            render.cleanPlated = true
        }
        _ = attempt
        return render
    }
    fatalError("Couldn’t capture a steady timer.")
}

/// The bars rectangle in pixels, half a point larger on every side for antialiasing.
func barsPlateRect(_ render: PillRender) -> PixelRect {
    let s = CGFloat(render.scale)
    let bars = render.barsRect
    let x0 = Int((bars.minX * s).rounded()) - 2
    let y0 = Int((bars.minY * s).rounded()) - 2
    let x1 = Int((bars.maxX * s).rounded()) + 2
    let y1 = Int((bars.maxY * s).rounded()) + 2
    return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

func pillTitle(_ state: PillState) -> String {
    switch state {
    case .listening(let handsFree, _, _): return handsFree ? "Hands-free" : "Listening"
    case .transcribing: return "Transcribing"
    case .result(let result):
        switch result {
        case .pasted: return "Pasted"
        case .copied: return "Copied"
        case .noSpeech: return "No speech heard"
        case .cancelled: return "Cancelled"
        default: return ""
        }
    }
}

func pillMeta(_ state: PillState) -> String? {
    switch state {
    case .listening(_, let seconds, _): return Format.duration(TimeInterval(seconds))
    case .transcribing(let badge): return badge?.uppercased()
    case .result(.pasted(let words)): return words == 1 ? "1 word" : "\(words) words"
    case .result(.copied): return "Press ⌘ V to paste"
    case .result(.noSpeech): return "Nothing pasted"
    default: return nil
    }
}

/// The pixel rectangle a sprite is trimmed to: everything with alpha, grown to whole points.
func trimRect(_ bitmap: Bitmap, scale: Int, including: CGRect? = nil) -> PixelRect {
    var rect = bitmap.opaqueBounds() ?? PixelRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
    if let including {
        let s = CGFloat(scale)
        rect = rect.union(PixelRect(x: Int((including.minX * s).rounded(.down)), y: Int((including.minY * s).rounded(.down)),
                                    width: Int((including.width * s).rounded(.up)), height: Int((including.height * s).rounded(.up))))
    }
    return rect.snappedToPoints(scale: scale, limitWidth: bitmap.width, limitHeight: bitmap.height)
}
