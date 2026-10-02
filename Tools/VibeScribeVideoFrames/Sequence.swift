// `sequence`: numbered PNG frames of the live overlay, driven by a level envelope.
//
// Per output frame i (t = i / fps seconds after frame 0, T = t0 + t film seconds):
//   level  = envelope level at (t - envelope_at), sample-and-hold at the envelope's fps
//   bars   = SpectrumBars formula at time floor(T * 30) / 30 (the TimelineView's 1/30 s entries)
//   timer  = floor(t - started_at) whole seconds (TimelineView .periodic(from: startedAt, by: 1))
// and the frame is the real pill (clean plate for that timer second) with ReplicaBars composited where
// SpectrumBars sits.

import AppKit
import SwiftUI
@testable import VibeScribeCore

/// `{"fps": 60, "levels": [0...1, ...]}`. levels[i] is the app's LevelMeter value at i / fps seconds.
/// Optional `"kind": "target"` means raw per-window targets; LevelMeter's smoothing is then applied here.
struct Envelope {
    var fps: Double
    var levels: [Float]
    var kind: String
    var source: String

    static let bufferDuration = 1024.0 / 48000.0

    private var meterTimes: [Double] = []
    private var meterLevels: [Float] = []

    init(fps: Double, levels: [Float], kind: String = "level", source: String = "") {
        self.fps = fps
        self.levels = levels
        self.kind = kind
        self.source = source
    }

    @MainActor
    static func load(_ url: URL) throws -> Envelope {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError("\(url.path): not a JSON object")
        }
        guard let fps = (json["fps"] as? NSNumber)?.doubleValue, fps > 0 else { throw ToolError("\(url.path): missing fps") }
        guard let raw = json["levels"] as? [NSNumber], !raw.isEmpty else { throw ToolError("\(url.path): missing levels") }
        var envelope = Envelope(fps: fps, levels: raw.map { min(max($0.floatValue, 0), 1) },
                                kind: json["kind"] as? String ?? "level", source: url.path)
        if envelope.kind == "target" { envelope.prepareMeter() }
        return envelope
    }

    var duration: Double { Double(levels.count) / fps }

    /// Runs the targets through the real LevelMeter at the tap's buffer rate.
    @MainActor
    private mutating func prepareMeter() {
        let meter = LevelMeter()
        var k = 0
        while true {
            let start = Double(k) * Self.bufferDuration
            if start > duration + 2 { break }
            let index = Int((start * fps).rounded(.down))
            meter.push(index < levels.count ? levels[index] : 0)
            meterTimes.append(start + Self.bufferDuration)
            meterLevels.append(meter.level)
            k += 1
        }
    }

    /// The meter level `t` seconds after levels[0].
    func level(at t: Double) -> Float {
        guard t >= 0 else { return 0 }
        if kind == "target" {
            // The meter value after the last buffer delivered by t.
            var lo = 0, hi = meterTimes.count - 1, found = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if meterTimes[mid] <= t + 1e-9 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return found >= 0 ? meterLevels[found] : 0
        }
        let index = Int((t * fps + 1e-6).rounded(.down))
        if index < levels.count { return levels[index] }
        // Past the end the voice is silent: LevelMeter releases by 15% of the gap per buffer.
        let buffers = Int(((t - duration) / Self.bufferDuration).rounded(.down)) + 1
        return levels[levels.count - 1] * Float(pow(0.85, Double(buffers)))
    }
}

enum SequenceState: String {
    case listening, handsfree, transcribing
}

enum SequenceLayer: String {
    case pill, bars, statusitem
}

@MainActor
func runSequence(_ args: Arguments) throws {
    let state = try SequenceState(rawValue: args.value("--state") ?? "listening")
        .orThrow("--state must be listening, handsfree or transcribing")
    let layer = try SequenceLayer(rawValue: args.value("--layer") ?? "pill").orThrow("--layer must be pill, bars or statusitem")
    let envelope = try args.value("--envelope").map { try Envelope.load(URL(fileURLWithPath: $0)) }
    if envelope == nil, state != .transcribing { throw ToolError("--envelope is required for listening and handsfree") }
    let out = URL(fileURLWithPath: try args.value("--out").orThrow("--out DIR is required"))
    let fps = try args.double("--fps") ?? envelope?.fps ?? 60
    let scale = try args.int("--scale") ?? 4
    let t0 = try args.double("--t0") ?? 0
    let envelopeAt = try args.double("--envelope-at") ?? 0
    let startedAt = try args.double("--started-at") ?? 0
    let quantize = try args.double("--quantize") ?? BarsMath.refreshRate
    let statusRate = try args.double("--status-rate") ?? 12
    let keycaps = (args.value("--keycaps") ?? "⌥").split(separator: ",").map(String.init)
    let badge = args.value("--badge") ?? "en"
    let prefix = args.value("--prefix") ?? "frame_"
    let startNumber = try args.int("--start-number") ?? 0
    let frames: Int
    if let count = try args.int("--frames") {
        frames = count
    } else if let duration = try args.double("--duration") {
        frames = Int((duration * fps).rounded())
    } else if let envelope {
        frames = Int(((envelope.duration + envelopeAt) * fps).rounded(.up))
    } else {
        throw ToolError("--frames or --duration is required without an envelope")
    }
    guard frames > 0 else { throw ToolError("nothing to render (0 frames)") }

    try ensureDirectory(out)
    // Old frames from a longer run would linger and confuse an encoder.
    if let old = try? FileManager.default.contentsOfDirectory(atPath: out.path) {
        for name in old where name.hasPrefix(prefix) && name.hasSuffix(".png") {
            try? FileManager.default.removeItem(at: out.appendingPathComponent(name))
        }
    }

    func time(_ i: Int) -> Double { Double(i) / fps }
    func levelAt(_ t: Double) -> Float { envelope?.level(at: t - envelopeAt) ?? 0 }
    func seconds(_ t: Double) -> Int { max(0, Int((t - startedAt + 1e-9).rounded(.down))) }

    print("Rendering \(frames) frames (\(state.rawValue), layer \(layer.rawValue), \(fps) fps, \(scale)x) into \(out.path)")
    let started = Date()
    var perFrame: [[String: Any]] = []
    var meta: [String: Any] = [
        "schema": "vibescribe-video-sequence/1",
        "state": state.rawValue,
        "layer": layer.rawValue,
        "fps": fps,
        "frames": frames,
        "scale": scale,
        "pattern": "\(prefix)%05d.png",
        "start_number": startNumber,
        "t0": t0,
        "envelope": envelope?.source ?? NSNull(),
        "envelope_kind": envelope?.kind ?? NSNull(),
        "envelope_at": envelopeAt,
        "started_at": startedAt,
        "bars_refresh_hz": quantize,
        "timing": "frame i shows t = i/fps s after frame 0 (film time t0 + t). level = envelope[floor((t - envelope_at) * env_fps)]; bars time = floor((t0 + t) * \(quantize)) / \(quantize); timer = floor(t - started_at).",
    ]

    switch layer {
    case .pill:
        let pillState: (Int) -> PillState = { second in
            switch state {
            case .listening: return .listening(handsFree: false, seconds: second, keycaps: keycaps)
            case .handsfree: return .listening(handsFree: true, seconds: second, keycaps: keycaps)
            case .transcribing: return .transcribing(badge: badge)
            }
        }
        let lastSecond = state == .transcribing ? 0 : seconds(time(frames - 1))
        if lastSecond > 59 { throw ToolError("timer would pass 0:59; the plates are rendered per second") }
        print("  rendering \(lastSecond + 1) plate(s)")
        var plates: [Int: PillRender] = [:]
        for second in 0...lastSecond { plates[second] = renderPill(pillState(second), scale: scale) }
        let first = plates[0]!
        for plate in plates.values where plate.pillRect != first.pillRect {
            throw ToolError("plates differ in size (\(plate.pillRect) vs \(first.pillRect))")
        }
        var trim = trimRect(first.bitmap, scale: scale, including: first.pillRect)
        for plate in plates.values { trim = trim.union(trimRect(plate.bitmap, scale: scale, including: plate.pillRect)) }
        let cropped = plates.mapValues { $0.bitmap.cropped(trim) }
        let s = CGFloat(scale)
        let offset = CGPoint(x: CGFloat(trim.x) / s, y: CGFloat(trim.y) / s)
        let pill = first.pillRect.offsetBy(dx: -offset.x, dy: -offset.y)
        let bars = first.barsRect.offsetBy(dx: -offset.x, dy: -offset.y)
        let barsX = Int(((bars.minX - PillGeometry.barsMargin) * s).rounded())
        let barsY = Int(((bars.minY - PillGeometry.barsMargin) * s).rounded())
        let barsRenderer = FrameRenderer(size: PillGeometry.barsLayerSize, scale: s)
        let shimmerSize = CGSize(width: first.pillRect.width.rounded(.up), height: PillGeometry.height)
        let shimmerRenderer = state == .transcribing ? FrameRenderer(size: shimmerSize, scale: s, origin: CGPoint(x: -9000, y: -7000)) : nil
        let pillX = Int((pill.minX * s).rounded()), pillY = Int((pill.minY * s).rounded())
        var lastBars: (BarsMath.Frame, Bitmap)?
        for i in 0..<frames {
            let t = time(i)
            let barsTime = BarsMath.quantized(t0 + t, rate: quantize)
            let level = levelAt(t)
            let second = state == .transcribing ? 0 : seconds(t)
            let mode: BarsMath.Mode = state == .transcribing ? .thinking : .live(level)
            let barsFrame = BarsMath.frame(mode, time: barsTime)
            let barsImage: Bitmap
            if let lastBars, lastBars.0 == barsFrame {
                barsImage = lastBars.1
            } else {
                barsImage = barsRenderer.render(ReplicaBars(frame: barsFrame).padding(PillGeometry.barsMargin))
                lastBars = (barsFrame, barsImage)
            }
            var canvas = cropped[second]!
            canvas.composite(barsImage, atX: barsX, y: barsY)
            if let shimmerRenderer {
                let shimmer = shimmerRenderer.render(ReplicaShimmer(size: first.pillRect.size, time: t0 + t))
                canvas.composite(shimmer, atX: pillX, y: pillY)
            }
            try canvas.writePNG(to: out.appendingPathComponent(String(format: "\(prefix)%05d.png", startNumber + i)))
            perFrame.append(["level": (Double(level) * 10000).rounded() / 10000, "timer": Format.duration(TimeInterval(second)), "bars_time": barsTime])
            if i % 60 == 0 { print("  frame \(i)/\(frames)") }
        }
        barsRenderer.close()
        shimmerRenderer?.close()
        meta["size_px"] = [trim.width, trim.height]
        meta["size_pt"] = [r3(CGFloat(trim.width) / s), r3(CGFloat(trim.height) / s)]
        meta["content_rect_pt"] = rectJSON(pill)
        meta["anchor"] = "top_center"
        meta["anchor_pt"] = [r3(pill.midX), r3(pill.minY)]
        meta["bars_rect_pt"] = rectJSON(bars)
        meta["placement_world"] = ["anchor": "top_center", "center_x": 720, "top": 42]
        meta["note"] = "Each frame is the whole pill with its shadow, same size and anchor as the matching pill_* sprite. Frames match pill_<state>_t<N> plus live bars."

    case .bars:
        let s = CGFloat(scale)
        let renderer = FrameRenderer(size: PillGeometry.barsLayerSize, scale: s)
        for i in 0..<frames {
            let t = time(i)
            let barsTime = BarsMath.quantized(t0 + t, rate: quantize)
            let level = levelAt(t)
            let mode: BarsMath.Mode = state == .transcribing ? .thinking : .live(level)
            let image = renderer.render(ReplicaBars(frame: BarsMath.frame(mode, time: barsTime)).padding(PillGeometry.barsMargin))
            try image.writePNG(to: out.appendingPathComponent(String(format: "\(prefix)%05d.png", startNumber + i)))
            perFrame.append(["level": (Double(level) * 10000).rounded() / 10000, "timer": Format.duration(TimeInterval(seconds(t))), "bars_time": barsTime])
            if i % 120 == 0 { print("  frame \(i)/\(frames)") }
        }
        renderer.close()
        let size = PillGeometry.barsLayerSize
        meta["size_px"] = [Int(size.width * s), Int(size.height * s)]
        meta["size_pt"] = [r3(size.width), r3(size.height)]
        meta["content_rect_pt"] = [Double(PillGeometry.barsMargin), Double(PillGeometry.barsMargin), 33, 16]
        meta["anchor"] = "top_left"
        meta["anchor_pt"] = [0, 0]
        meta["offset_in_pill_pt"] = [Double(PillGeometry.barsOrigin.x - PillGeometry.barsMargin), Double(PillGeometry.barsOrigin.y - PillGeometry.barsMargin)]
        meta["note"] = "Bars only (transparent). Place the frame's top-left at pill_sprite.bars_rect_pt origin minus (2, 2) pt, i.e. pill body top-left + offset_in_pill_pt. Timer changes are listed per frame; swap pill_<state>_t<N> accordingly."

    case .statusitem:
        let s = CGFloat(scale)
        // MenuBarController refreshes the button 12 times a second; the title rounds the elapsed time.
        let canvas = CGSize(width: 100, height: 36)
        let renderer = FrameRenderer(size: canvas, scale: s)
        MeasureStore.shared.rects = [:]
        func content(_ t: Double) -> (StatusItemContent, String) {
            let refresh = BarsMath.quantized(t0 + t, rate: statusRate)
            let tr = refresh - t0
            switch state {
            case .listening, .handsfree:
                let level = CGFloat(levelAt(tr))
                let title = Format.duration(max(0, tr - startedAt))
                return (StatusItemContent(image: StatusIcons.bars(level: level, time: refresh), title: title), title)
            case .transcribing:
                return (StatusItemContent(image: StatusIcons.thinking(time: refresh), title: badge.uppercased()), badge.uppercased())
            }
        }
        _ = renderer.render(content(0).0.measure("item").padding(8))
        guard let item = MeasureStore.shared.rects["item"] else { throw ToolError("status item not measured") }
        let crop = PixelRect(x: Int(((item.minX - 2) * s).rounded(.down)), y: Int(((item.minY - 2) * s).rounded(.down)),
                             width: Int(((item.width + 4) * s).rounded(.up)), height: Int(((item.height + 4) * s).rounded(.up)))
            .snappedToPoints(scale: scale, limitWidth: Int(canvas.width * s), limitHeight: Int(canvas.height * s))
        var last: (String, Double, Bitmap)?
        for i in 0..<frames {
            let t = time(i)
            let refresh = BarsMath.quantized(t0 + t, rate: statusRate)
            let (view, title) = content(t)
            let image: Bitmap
            if let last, last.0 == title, last.1 == refresh {
                image = last.2
            } else {
                image = renderer.render(view.measure("item").padding(8)).cropped(crop)
                last = (title, refresh, image)
            }
            try image.writePNG(to: out.appendingPathComponent(String(format: "\(prefix)%05d.png", startNumber + i)))
            perFrame.append(["level": (Double(levelAt(refresh - t0)) * 10000).rounded() / 10000, "title": title, "refresh_time": refresh])
            if i % 120 == 0 { print("  frame \(i)/\(frames)") }
        }
        renderer.close()
        let local = item.offsetBy(dx: -CGFloat(crop.x) / s, dy: -CGFloat(crop.y) / s)
        meta["size_px"] = [crop.width, crop.height]
        meta["size_pt"] = [r3(CGFloat(crop.width) / s), r3(CGFloat(crop.height) / s)]
        meta["content_rect_pt"] = rectJSON(local)
        meta["anchor"] = "center"
        meta["anchor_pt"] = [r3(local.midX), r3(local.midY)]
        meta["status_refresh_hz"] = statusRate
        meta["note"] = "StatusIcons.bars(level, time) + \" \" + Format.duration(elapsed) (rounded), redrawn at status_refresh_hz like MenuBarController. Centre anchor_pt on the status item position (spec stage.menubar.status_item)."
    }

    meta["per_frame"] = perFrame
    var changes: [[String: Any]] = []
    var previous: String?
    for (index, frame) in perFrame.enumerated() {
        let label = (frame["timer"] ?? frame["title"]) as? String
        if label != previous { changes.append(["frame": index, "text": label ?? ""]); previous = label }
    }
    meta["timer_changes"] = changes
    try writeJSON(meta, to: out.appendingPathComponent("sequence.json"))
    print(String(format: "wrote %d frames + sequence.json in %.1f s", frames, Date().timeIntervalSince(started)))
}

extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else { throw ToolError(message) }
        return value
    }
}
