// `verify`: checks that the replica bars, the clean plates and the composite reproduce the real views.
//
// The real SpectrumBars takes its time from a TimelineView that can't be stepped, so each check hosts a
// probe TimelineView with the same schedule next to it, records the dates it sees, captures, and then
// renders the replica at each recent probe date. The best match is reported.

import AppKit
import SwiftUI
@testable import VibeScribeCore

@MainActor
final class ProbeClock {
    static let shared = ProbeClock()
    static let shimmer = ProbeClock()
    var dates: [TimeInterval] = []

    func record(_ date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        if dates.last != t { dates.append(t) }
        if dates.count > 400 { dates.removeFirst(200) }
    }
}

/// A 1×1 clear TimelineView on the bars' schedule (or, with `throttled` off, the shimmer's plain
/// `.animation` schedule) that records its dates.
private struct Probe: View {
    var throttled = true
    var body: some View {
        if throttled {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let _ = ProbeClock.shared.record(context.date)
                Color.clear.frame(width: 1, height: 1)
            }
        } else {
            TimelineView(.animation) { context in
                let _ = ProbeClock.shimmer.record(context.date)
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }
}

private struct ProbedBars: View {
    var mode: SpectrumBars.Mode
    var body: some View {
        ZStack(alignment: .topLeading) {
            Probe()
            SpectrumBars(mode: mode).padding(PillGeometry.barsMargin)
        }
    }
}

private struct ProbedPill: View {
    @ObservedObject var model: OverlayModel
    var level: Float
    var body: some View {
        ZStack(alignment: .topLeading) {
            Probe()
            Probe(throttled: false)
            OverlayPill(phase: model.phase, model: model, level: level)
                .measure("pill")
                .padding(PillCanvas.bleed)
        }
    }
}

private func describe(_ d: Bitmap.Difference) -> [String: Any] {
    [
        "max_delta": d.maxDelta,
        "differing_pixels": d.differingPixels,
        "pixels_over_2": d.pixelsOverTwo,
        "mean_delta": (d.meanDelta * 10000).rounded() / 10000,
        "pixels": d.total,
    ]
}

private func line(_ name: String, _ d: Bitmap.Difference, _ extra: String = "") -> String {
    String(format: "%@: max Δ %d, %d/%d px differ, %d px Δ>2, mean %.4f %@", name, d.maxDelta, d.differingPixels, d.total, d.pixelsOverTwo, d.meanDelta, extra)
}

/// Amplified absolute difference, opaque, for looking at.
private func differenceImage(_ a: Bitmap, _ b: Bitmap, gain: Int = 16) -> Bitmap {
    var out = Bitmap(width: a.width, height: a.height)
    for i in stride(from: 0, to: a.data.count, by: 4) {
        var m = 0
        for c in 0..<4 { m = max(m, abs(Int(a.data[i + c]) - Int(b.data[i + c]))) }
        let v = UInt8(min(255, m * gain))
        out.data[i] = v; out.data[i + 1] = v; out.data[i + 2] = v; out.data[i + 3] = 255
    }
    return out
}

@MainActor
func runVerify(_ args: Arguments) throws {
    let out = URL(fileURLWithPath: args.value("--out") ?? "video/build/verify")
    try ensureDirectory(out)
    let scale = 4
    let s = CGFloat(scale)
    var report: [String: Any] = [:]
    var failures: [String] = []

    // (a) Real SpectrumBars vs ReplicaBars at the probe's dates.
    print("(a) SpectrumBars vs ReplicaBars")
    let replica = FrameRenderer(size: PillGeometry.barsLayerSize, scale: s)
    var barsResults: [[String: Any]] = []
    let modes: [(String, SpectrumBars.Mode, BarsMath.Mode)] = [
        ("live 0.15", .live(0.15), .live(0.15)),
        ("live 0.55", .live(0.55), .live(0.55)),
        ("live 0.9", .live(0.9), .live(0.9)),
        ("live 1.0", .live(1.0), .live(1.0)),
        ("thinking", .thinking, .thinking),
        ("still", .still, .still),
    ]
    for (name, real, mine) in modes {
        for trial in 0..<3 {
            ProbeClock.shared.dates = []
            let host = Host(ProbedBars(mode: real), size: PillGeometry.barsLayerSize, origin: CGPoint(x: -8000, y: -6000))
            host.wait(0.25 + 0.07 * Double(trial))
            let captured = host.capture(scale: s)
            let candidates = Array(ProbeClock.shared.dates.suffix(6))
            host.close()
            var best: (Bitmap.Difference, TimeInterval, Bitmap)?
            for t in candidates.isEmpty ? [0] : candidates {
                let image = replica.render(ReplicaBars(frame: BarsMath.frame(mine, time: t)).padding(PillGeometry.barsMargin))
                let d = captured.difference(image)
                if best == nil || d.meanDelta < best!.0.meanDelta { best = (d, t, image) }
            }
            guard let best else { continue }
            let rank = candidates.firstIndex(of: best.1).map { candidates.count - 1 - $0 } ?? -1
            print("  " + line("\(name) #\(trial)", best.0, "(probe date \(rank) frames before capture, \(candidates.count) candidates)"))
            var entry = describe(best.0)
            entry["mode"] = name
            entry["trial"] = trial
            entry["probe_candidates"] = candidates.count
            entry["matched_probe_rank"] = rank
            barsResults.append(entry)
            if trial == 0 {
                let slug = name.replacingOccurrences(of: " ", with: "_")
                try captured.writePNG(to: out.appendingPathComponent("bars_\(slug)_real.png"))
                try best.2.writePNG(to: out.appendingPathComponent("bars_\(slug)_replica.png"))
                try differenceImage(captured, best.2).writePNG(to: out.appendingPathComponent("bars_\(slug)_diff16.png"))
            }
            if best.0.maxDelta > 3 { failures.append("bars \(name) #\(trial): max Δ \(best.0.maxDelta)") }
        }
    }
    report["bars_real_vs_replica"] = barsResults

    // (d) The persistent FrameRenderer gives the same pixels as a fresh one.
    print("(d) FrameRenderer reuse")
    let frameA = BarsMath.frame(.live(0.8), time: 1234.5)
    let frameB = BarsMath.frame(.thinking, time: 99.1)
    _ = replica.render(ReplicaBars(frame: frameB).padding(PillGeometry.barsMargin))
    let reused = replica.render(ReplicaBars(frame: frameA).padding(PillGeometry.barsMargin))
    let fresh = FrameRenderer(size: PillGeometry.barsLayerSize, scale: s, origin: CGPoint(x: -9500, y: -8000))
    let freshImage = fresh.render(ReplicaBars(frame: frameA).padding(PillGeometry.barsMargin))
    fresh.close()
    let reuse = reused.difference(freshImage)
    print("  " + line("reused vs fresh", reuse))
    report["frame_renderer_reuse"] = describe(reuse)
    if reuse.maxDelta > 0 { failures.append("FrameRenderer reuse differs (max Δ \(reuse.maxDelta))") }

    // (b) Real pill with still bars vs clean plate + ReplicaBars(.still).
    print("(b) pill: real still bars vs plate + replica")
    let state = PillState.listening(handsFree: false, seconds: 3, keycaps: ["⌥"])
    let realStill = renderPill(state, scale: scale, cleanPlate: false)
    let plate = renderPill(state, scale: scale, cleanPlate: true)
    let barsX = Int(((plate.barsRect.minX - PillGeometry.barsMargin) * s).rounded())
    let barsY = Int(((plate.barsRect.minY - PillGeometry.barsMargin) * s).rounded())
    let stillBars = replica.render(ReplicaBars(frame: BarsMath.frame(.still, time: 0)).padding(PillGeometry.barsMargin))
    var composed = plate.bitmap
    composed.composite(stillBars, atX: barsX, y: barsY)
    let trim = trimRect(realStill.bitmap, scale: scale, including: realStill.pillRect)
    let stillDiff = realStill.bitmap.cropped(trim).difference(composed.cropped(trim))
    let plateRect = barsPlateRect(plate)
    let stillBarsDiff = realStill.bitmap.difference(composed, in: plateRect)
    print("  " + line("whole pill", stillDiff))
    print("  " + line("bars area", stillBarsDiff))
    report["pill_still_real_vs_composite"] = ["whole": describe(stillDiff), "bars_area": describe(stillBarsDiff)]
    try realStill.bitmap.cropped(trim).writePNG(to: out.appendingPathComponent("pill_still_real.png"))
    try composed.cropped(trim).writePNG(to: out.appendingPathComponent("pill_still_composite.png"))
    try plate.bitmap.cropped(trim).writePNG(to: out.appendingPathComponent("pill_plate.png"))
    try differenceImage(realStill.bitmap.cropped(trim), composed.cropped(trim)).writePNG(to: out.appendingPathComponent("pill_still_diff16.png"))
    if stillDiff.maxDelta > 4 { failures.append("still pill composite: max Δ \(stillDiff.maxDelta)") }

    // (c) Real live pill (moving bars) vs plate + ReplicaBars(.live) at the probe's date.
    print("(c) pill: real live bars vs plate + replica")
    var liveResults: [[String: Any]] = []
    for (trial, level) in [Float(0.35), 0.7, 1.0].enumerated() {
        let model = OverlayModel(level: LevelMeter())
        model.shortcutKeycaps = ["⌥"]
        let startedAt = Date().addingTimeInterval(-3.05)
        model.showListening(handsFree: false, startedAt: startedAt)
        ProbeClock.shared.dates = []
        MeasureStore.shared.rects = [:]
        let host = Host(ProbedPill(model: model, level: level), size: PillCanvas.size, origin: CGPoint(x: -8000, y: -6500))
        host.wait(0.35)
        let captured = host.capture(scale: s)
        let candidates = Array(ProbeClock.shared.dates.suffix(6))
        let rect = MeasureStore.shared.rects["pill"] ?? .zero
        host.close()
        if Date().timeIntervalSince(startedAt) >= 3.95 { print("  (timer may have ticked; skipping trial \(trial))"); continue }
        if rect != plate.pillRect { failures.append("live pill rect \(rect) ≠ plate rect \(plate.pillRect)") }
        var best: (Bitmap.Difference, TimeInterval, Bitmap)?
        for t in candidates {
            let bars = replica.render(ReplicaBars(frame: BarsMath.frame(.live(level), time: t)).padding(PillGeometry.barsMargin))
            var image = plate.bitmap
            image.composite(bars, atX: barsX, y: barsY)
            let d = captured.cropped(trim).difference(image.cropped(trim))
            if best == nil || d.meanDelta < best!.0.meanDelta { best = (d, t, image) }
        }
        guard let best else { failures.append("live pill: the probe recorded no dates"); continue }
        print("  " + line("level \(level)", best.0))
        var entry = describe(best.0)
        entry["level"] = Double(level)
        liveResults.append(entry)
        if trial == 1 {
            try captured.cropped(trim).writePNG(to: out.appendingPathComponent("pill_live_real.png"))
            try best.2.cropped(trim).writePNG(to: out.appendingPathComponent("pill_live_composite.png"))
            try differenceImage(captured.cropped(trim), best.2.cropped(trim)).writePNG(to: out.appendingPathComponent("pill_live_diff16.png"))
        }
        if best.0.maxDelta > 6 { failures.append("live pill level \(level): max Δ \(best.0.maxDelta)") }
    }
    report["pill_live_real_vs_composite"] = liveResults

    // (e) Real transcribing pill (thinking bars + shimmer moving) vs plate + replica bars + replica shimmer.
    print("(e) pill: real transcribing vs plate + replica bars + replica shimmer")
    let thinkingState = PillState.transcribing(badge: "en")
    let thinkingPlate = renderPill(thinkingState, scale: scale, cleanPlate: true)
    let thinkingTrim = trimRect(thinkingPlate.bitmap, scale: scale, including: thinkingPlate.pillRect)
    let shimmerRenderer = FrameRenderer(size: CGSize(width: thinkingPlate.pillRect.width.rounded(.up), height: PillGeometry.height),
                                        scale: s, origin: CGPoint(x: -9000, y: -7000))
    let tx = Int(((thinkingPlate.barsRect.minX - PillGeometry.barsMargin) * s).rounded())
    let ty = Int(((thinkingPlate.barsRect.minY - PillGeometry.barsMargin) * s).rounded())
    let px = Int((thinkingPlate.pillRect.minX * s).rounded()), py = Int((thinkingPlate.pillRect.minY * s).rounded())
    var shimmerResults: [[String: Any]] = []
    for trial in 0..<3 {
        let (model, _) = makeOverlayModel(thinkingState)
        ProbeClock.shared.dates = []
        ProbeClock.shimmer.dates = []
        MeasureStore.shared.rects = [:]
        let host = Host(ProbedPill(model: model, level: 0), size: PillCanvas.size, origin: CGPoint(x: -8000, y: -6500))
        host.wait(0.3 + 0.37 * Double(trial))
        let captured = host.capture(scale: s)
        let barDates = Array(ProbeClock.shared.dates.suffix(4))
        let shimmerDates = Array(ProbeClock.shimmer.dates.suffix(4))
        host.close()
        var best: (Bitmap.Difference, Bitmap)?
        for b in barDates {
            let bars = replica.render(ReplicaBars(frame: BarsMath.frame(.thinking, time: b)).padding(PillGeometry.barsMargin))
            for t in shimmerDates {
                var image = thinkingPlate.bitmap
                image.composite(bars, atX: tx, y: ty)
                image.composite(shimmerRenderer.render(ReplicaShimmer(size: thinkingPlate.pillRect.size, time: t)), atX: px, y: py)
                let d = captured.cropped(thinkingTrim).difference(image.cropped(thinkingTrim))
                if best == nil || d.meanDelta < best!.0.meanDelta { best = (d, image) }
            }
        }
        guard let best else { failures.append("transcribing pill: the probes recorded no dates"); continue }
        print("  " + line("transcribing #\(trial)", best.0))
        shimmerResults.append(describe(best.0))
        if trial == 0 {
            try captured.cropped(thinkingTrim).writePNG(to: out.appendingPathComponent("pill_transcribing_real.png"))
            try best.1.cropped(thinkingTrim).writePNG(to: out.appendingPathComponent("pill_transcribing_composite.png"))
            try differenceImage(captured.cropped(thinkingTrim), best.1.cropped(thinkingTrim)).writePNG(to: out.appendingPathComponent("pill_transcribing_diff16.png"))
        }
        if best.0.maxDelta > 6 { failures.append("transcribing pill #\(trial): max Δ \(best.0.maxDelta)") }
    }
    shimmerRenderer.close()
    report["pill_transcribing_real_vs_composite"] = shimmerResults
    replica.close()

    report["failures"] = failures
    report["note"] = "Δ is the largest per-channel difference (0-255, premultiplied RGBA) at \(scale)x. Bars: real SpectrumBars captured next to a probe TimelineView on the same 1/30 s schedule, replica rendered at each recent probe date, best match kept."
    try writeJSON(report, to: out.appendingPathComponent("verify.json"))
    print(failures.isEmpty ? "verify: all checks passed" : "verify: \(failures.count) issue(s):\n  " + failures.joined(separator: "\n  "))
    print("wrote \(out.path)/verify.json")
}
