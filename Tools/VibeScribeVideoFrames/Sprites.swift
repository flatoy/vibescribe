// `sprites`: every still in video/spec.json "sprites", plus a few extras, as trimmed transparent PNGs with
// a manifest. Each sprite is the real VibeScribeCore view rendered at the sprite's pixel density.

import AppKit
import SwiftUI
@testable import VibeScribeCore

@MainActor
final class SpriteWriter {
    let folder: URL
    private(set) var entries: [[String: Any]] = []
    private(set) var warnings: [String] = []

    init(folder: URL) throws {
        self.folder = folder
        try ensureDirectory(folder)
    }

    /// Trims `canvas` to its visible pixels (whole points), writes `<id>.png` and `<id>.json`, and records
    /// the manifest entry. Rects are canvas points; they're stored relative to the trimmed PNG.
    func emit(
        id: String,
        canvas: Bitmap,
        scale: Int,
        content: CGRect,
        anchor: Anchor,
        group: String,
        extra: [String: Any] = [:],
        rects: [String: CGRect] = [:]
    ) throws {
        let trim = trimRect(canvas, scale: scale, including: content)
        if canvas.touchesEdge {
            warn("\(id): pixels reach the canvas edge; the shadow may be clipped")
        }
        let image = canvas.cropped(trim)
        let s = CGFloat(scale)
        let offset = CGPoint(x: CGFloat(trim.x) / s, y: CGFloat(trim.y) / s)
        func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -offset.x, dy: -offset.y) }
        let contentLocal = local(content)
        let anchorPoint = anchor.point(in: contentLocal)
        let url = folder.appendingPathComponent("\(id).png")
        try image.writePNG(to: url)

        var entry: [String: Any] = [
            "id": id,
            "file": "\(id).png",
            "group": group,
            "scale": scale,
            "size_px": [image.width, image.height],
            "size_pt": [r3(CGFloat(image.width) / s), r3(CGFloat(image.height) / s)],
            "content_rect_pt": rectJSON(contentLocal),
            "anchor": anchor.rawValue,
            "anchor_pt": [r3(anchorPoint.x), r3(anchorPoint.y)],
        ]
        for (key, rect) in rects { entry[key] = rectJSON(local(rect)) }
        for (key, value) in extra { entry[key] = value }
        entries.append(entry)

        // The sidecar the spec asks for: {id, size_pt, scale, content_rect_pt}, plus the anchor.
        var sidecar: [String: Any] = [:]
        for key in ["id", "size_pt", "scale", "content_rect_pt", "anchor", "anchor_pt", "size_px"] { sidecar[key] = entry[key] }
        for key in rects.keys { sidecar[key] = entry[key] }
        try writeJSON(sidecar, to: folder.appendingPathComponent("\(id).json"))
        print("  \(id)  \(image.width)x\(image.height) px @\(scale)x")
    }

    func record(_ entry: [String: Any]) {
        entries.append(entry)
    }

    func warn(_ message: String) {
        warnings.append(message)
        print("  WARNING: \(message)")
    }

    func writeManifest(merging: Bool) throws {
        let url = folder.appendingPathComponent("manifest.json")
        var all = entries
        if merging, let data = try? Data(contentsOf: url),
           let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oldSprites = old["sprites"] as? [[String: Any]] {
            let fresh = Set(entries.compactMap { $0["id"] as? String })
            all = oldSprites.filter { !fresh.contains($0["id"] as? String ?? "") } + entries
        }
        let order = specOrder()
        all.sort { a, b in
            let ia = order[a["id"] as? String ?? ""] ?? Int.max
            let ib = order[b["id"] as? String ?? ""] ?? Int.max
            return ia != ib ? ia < ib : (a["id"] as? String ?? "") < (b["id"] as? String ?? "")
        }
        let manifest: [String: Any] = [
            "schema": "vibescribe-video-sprites/1",
            "generator": "swift run --scratch-path .build-video VibeScribeVideoFrames sprites (Tools/VibeScribeVideoFrames)",
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "units": "Rects and points are in sprite points from the PNG's top-left corner; 1 pt = `scale` px. content_rect_pt is the view itself (pill body, window, picker panel, keycap, glyph layout box) without its shadow; anchor_pt is the named anchor of content_rect_pt.",
            "colour": "sRGB, straight alpha PNG (written from premultiplied buffers)",
            "warnings": warnings,
            "sprites": all,
        ]
        try writeJSON(manifest, to: url)
        print("wrote \(url.path) (\(all.count) sprites)")
    }
}

enum Anchor: String {
    case topCenter = "top_center"
    case topLeft = "top_left"
    case center

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topCenter: return CGPoint(x: rect.midX, y: rect.minY)
        case .topLeft: return rect.origin
        case .center: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}

func specOrder() -> [String: Int] {
    let url = URL(fileURLWithPath: "video/spec.json")
    guard let data = try? Data(contentsOf: url),
          let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sprites = spec["sprites"] as? [[String: Any]] else { return [:] }
    var order: [String: Int] = [:]
    for (index, sprite) in sprites.enumerated() {
        if let id = sprite["id"] as? String { order[id] = index }
    }
    return order
}

// MARK: Catalogue

struct SpriteJob {
    var id: String
    var group: String
    var run: @MainActor (SpriteWriter) throws -> Void
}

@MainActor
func spriteJobs() -> [SpriteJob] {
    var jobs: [SpriteJob] = []

    // Overlay pills, 4×.
    for seconds in 0...7 {
        jobs.append(pillJob("pill_listening_t\(seconds)", .listening(handsFree: false, seconds: seconds, keycaps: ["⌥"]),
                            state: ["phase": "listening", "handsFree": false, "timer": Format.duration(TimeInterval(seconds))]))
    }
    for seconds in 0...4 {
        jobs.append(pillJob("pill_handsfree_t\(seconds)", .listening(handsFree: true, seconds: seconds, keycaps: ["⌥"]),
                            state: ["phase": "listening", "handsFree": true, "timer": Format.duration(TimeInterval(seconds)), "keycaps": ["⌥"]]))
    }
    for badge in ["en", "de"] {
        jobs.append(pillJob("pill_transcribing_\(badge)", .transcribing(badge: badge), state: ["phase": "transcribing", "badge": badge.uppercased()]))
    }
    for words in [19, 18, 10, 11, 6] {
        jobs.append(pillJob("pill_pasted_\(words)", .result(.pasted(words: words)), state: ["phase": "pasted", "words": words]))
    }
    jobs.append(pillJob("pill_copied", .result(.copied), state: ["phase": "copied"], extra: true))
    jobs.append(pillJob("pill_nospeech", .result(.noSpeech), state: ["phase": "noSpeech"], extra: true))
    jobs.append(SpriteJob(id: "pill_listening_sample", group: "pill") { writer in try pillSample(writer) })

    // Language picker, 4×.
    for query in ["", "g", "ge", "ger"] {
        let id = query.isEmpty ? "picker_before_q0" : "picker_before_\(query)"
        jobs.append(SpriteJob(id: id, group: "picker") { writer in
            try pickerSprite(writer, id: id, query: query, recent: [Film.french, Film.japanese, .english])
        })
    }
    jobs.append(SpriteJob(id: "picker_montage", group: "picker") { writer in
        try pickerSprite(writer, id: "picker_montage", query: "", recent: [Film.japanese, Film.german, .english])
    })

    // Settings windows, 3×.
    for (suffix, query) in [("q0", ""), ("q_o", "o"), ("q_oa", "oa"), ("q_oat", "oat")] {
        let id = "settings_history_\(suffix)"
        jobs.append(SpriteJob(id: id, group: "settings") { writer in try historySprite(writer, id: id, query: query) })
    }
    let vocabularySteps = ["", ",", ", ", ", S", ", Sw", ", Swi", ", Swif", ", Swift", ", SwiftU", ", SwiftUI"]
    for (index, step) in vocabularySteps.enumerated() {
        let id = "settings_language_vocab_\(index)"
        jobs.append(SpriteJob(id: id, group: "settings") { writer in
            try vocabularySprite(writer, id: id, vocabulary: Film.vocabulary + step)
        })
    }
    jobs.append(SpriteJob(id: "settings_shortcut_default", group: "settings") { writer in
        try shortcutSprite(writer, id: "settings_shortcut_default", hotkey: .pushToTalkDefault, recording: false)
    })
    jobs.append(SpriteJob(id: "settings_shortcut_recording", group: "settings") { writer in
        try shortcutSprite(writer, id: "settings_shortcut_recording", hotkey: .pushToTalkDefault, recording: true)
    })
    jobs.append(SpriteJob(id: "settings_shortcut_custom", group: "settings") { writer in
        try shortcutSprite(writer, id: "settings_shortcut_custom", hotkey: rightCommandHotkey, recording: false)
    })
    jobs.append(SpriteJob(id: "settings_model_ready", group: "settings") { writer in
        try settingsSprite(writer, id: "settings_model_ready", page: .model, state: ["page": "model", "large_v3": "ready", "large_v3_turbo": "not downloaded"])
    })

    // Keycaps, 4×.
    for (id, label) in [("keycap_right_option", "Right ⌥"), ("keycap_option", "⌥"), ("keycap_shift", "⇧"),
                        ("keycap_return", "↩"), ("keycap_right_command", "Right ⌘")] {
        jobs.append(SpriteJob(id: id, group: "keycap") { writer in try keycapSprite(writer, id: id, label: label) })
    }

    // Menu bar glyphs, 4×.
    for (id, symbol, size, weight) in [
        ("glyph_waveform", "waveform", 13.0, Font.Weight.medium),
        ("glyph_wifi", "wifi", 13.0, .medium),
        ("glyph_wifi_slash", "wifi.slash", 13.0, .medium),
        ("glyph_battery_75", "battery.75percent", 13.0, .medium),
        ("glyph_apple_logo", "apple.logo", 14.0, .regular),
    ] {
        jobs.append(SpriteJob(id: id, group: "glyph") { writer in
            try glyphSprite(writer, id: id, symbol: symbol, size: CGFloat(size), weight: weight)
        })
    }

    // Status item (extras), 4×.
    for (id, badge) in [("statusitem_idle_en", "EN"), ("statusitem_idle_de", "DE"), ("statusitem_idle_auto", "AUTO")] {
        jobs.append(SpriteJob(id: id, group: "statusitem") { writer in
            try statusItemSprite(writer, id: id, image: StatusIcons.waveform, title: badge, state: ["phase": "ready", "title": badge])
        })
    }
    jobs.append(SpriteJob(id: "statusitem_recording_sample", group: "statusitem") { writer in
        try statusItemSprite(writer, id: "statusitem_recording_sample", image: StatusIcons.bars(level: 0.7, time: 812_345_678.25),
                             title: Format.duration(3), state: ["phase": "recording", "title": "0:03", "level": 0.7, "note": "one frame; use `sequence --layer statusitem` for motion"])
    })
    jobs.append(SpriteJob(id: "statusitem_transcribing_en", group: "statusitem") { writer in
        try statusItemSprite(writer, id: "statusitem_transcribing_en", image: StatusIcons.thinking(time: 812_345_678.1),
                             title: "EN", state: ["phase": "transcribing", "title": "EN", "note": "one frame of the thinking wave"])
    })

    jobs.append(SpriteJob(id: "icon_app", group: "icon") { writer in try iconSprite(writer) })
    return jobs
}

// MARK: Pills

@MainActor
private func pillJob(_ id: String, _ state: PillState, state json: [String: Any], extra: Bool = false) -> SpriteJob {
    SpriteJob(id: id, group: "pill") { writer in
        let scale = 4
        let render = renderPill(state, scale: scale, cleanPlate: isLive(state))
        var info: [String: Any] = [
            "state": json,
            "clean_plated": render.cleanPlated,
            "text": ["title": render.title, "meta": render.meta.map { $0 as Any } ?? NSNull()] as [String: Any],
            "placement_world": ["anchor": "top_center", "center_x": 720, "top": 42],
        ]
        if extra { info["extra"] = true }
        var rects: [String: CGRect] = [:]
        if render.cleanPlated {
            rects["bars_rect_pt"] = render.barsRect
            info["bars_note"] = "Bars painted out; draw SpectrumBars (barWidth 3, spacing 2, height 16) inside bars_rect_pt, or use `sequence`."
        }
        if state.hasShimmer {
            info["shimmer_removed"] = true
        }
        try writer.emit(id: id, canvas: render.bitmap, scale: scale, content: render.pillRect, anchor: .topCenter,
                        group: "pill", extra: info, rects: rects)
    }
}

func isLive(_ state: PillState) -> Bool {
    switch state {
    case .listening, .transcribing: return true
    case .result: return false
    }
}

/// A listening pill with bars, for stills: the 0:03 plate plus ReplicaBars at level 0.72.
@MainActor
private func pillSample(_ writer: SpriteWriter) throws {
    let scale = 4
    let render = renderPill(.listening(handsFree: false, seconds: 3, keycaps: ["⌥"]), scale: scale)
    let renderer = FrameRenderer(size: PillGeometry.barsLayerSize, scale: CGFloat(scale))
    let time = BarsMath.quantized(812_345_678.4)
    let bars = renderer.render(ReplicaBars(frame: BarsMath.frame(.live(0.72), time: time)).padding(PillGeometry.barsMargin))
    renderer.close()
    var canvas = render.bitmap
    let origin = render.barsRect.origin
    canvas.composite(bars, atX: Int(((origin.x - PillGeometry.barsMargin) * CGFloat(scale)).rounded()),
                     y: Int(((origin.y - PillGeometry.barsMargin) * CGFloat(scale)).rounded()))
    try writer.emit(id: "pill_listening_sample", canvas: canvas, scale: scale, content: render.pillRect, anchor: .topCenter,
                    group: "pill", extra: ["state": ["phase": "listening", "timer": "0:03", "level": 0.72], "extra": true,
                                           "text": ["title": "Listening", "meta": "0:03"]],
                    rects: ["bars_rect_pt": render.barsRect])
}

// MARK: Picker

@MainActor
private func pickerSprite(_ writer: SpriteWriter, id: String, query: String, recent: [WhisperLanguage]) throws {
    let scale = 4
    let preferences = filmPreferences(recent: recent)
    let model = LanguagePickerModel(preferences: preferences)
    model.query = query
    model.highlightIndex = 0
    let bleed: CGFloat = 12
    let size = LanguagePickerView.size
    var caret: CGRect?
    let shot = snapshot(
        LanguagePickerView(model: model).measure("picker").padding(bleed),
        size: CGSize(width: size.width + bleed * 2, height: size.height + bleed * 2),
        scale: CGFloat(scale)
    ) { host in
        // The view focuses its search field (.task), which selects the text. Note where the caret would be
        // at the end of the query, then drop the focus so the shot has no caret or selection.
        if let editor = host.window.firstResponder as? NSTextView {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            caret = caretRect(of: editor, in: host)
        }
        host.window.makeFirstResponder(nil)
    }
    let rows = model.rows
    let label = query.isEmpty ? "now: \(preferences.language.badge.lowercased())" : (rows.count == 1 ? "1 result" : "\(rows.count) results")
    let expected: [String: String] = ["": "now: en", "g": "22 results", "ge": "6 results", "ger": "2 results"]
    if id.hasPrefix("picker_before"), let want = expected[query], want != label {
        writer.warn("\(id): right label is \(label), the spec expects \(want)")
    }
    var sections: [String: [String]] = [:]
    for row in rows where row.section != .all && row.section != .results {
        sections[row.section.rawValue, default: []].append(row.language.displayName)
    }
    var info: [String: Any] = [
        "state": ["query": query, "language": preferences.language.rawValue, "highlight_index": model.highlightIndex],
        "text": [
            "right_label": label,
            "highlighted": rows.indices.contains(model.highlightIndex) ? rows[model.highlightIndex].language.displayName : NSNull(),
            "first_rows": rows.prefix(6).map { row in
                [row.language.displayName, row.language.nativeName ?? "", row.language.whisperCode ?? "auto"]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            },
            "pinned": sections["Pinned"] ?? [],
            "recent": sections["Recent"] ?? [],
            "result_count": rows.count,
        ],
        "shadow": "none in the sprite; the stage draws 0 18px 50px rgba(0,0,0,0.5)",
        "placement_world": ["anchor": "top_center", "center_x": 720, "top": 106],
    ]
    var rects: [String: CGRect] = [:]
    if let caret { rects["caret_rect_pt"] = caret; info["caret_note"] = "Caret at the end of the query (the sprite has none)." }
    guard let picker = shot.rects["picker"] else { throw ToolError("picker not measured") }
    try writer.emit(id: id, canvas: shot.bitmap, scale: scale, content: picker, anchor: .topCenter, group: "picker",
                    extra: info, rects: rects)
}

// MARK: Settings

@MainActor
private enum SettingsCanvas {
    static let bleed: CGFloat = 110
    static var size: CGSize {
        CGSize(width: SettingsView.size.width + bleed * 2, height: SettingsView.size.height + bleed * 2)
    }
}

@MainActor
private func settingsScene(_ film: FilmContext, page: SettingsPage) -> some View {
    let navigation = SettingsNavigation()
    navigation.page = page
    return WindowFrame(size: SettingsView.size) {
        SettingsView(context: film.context, navigation: navigation)
    }
    .measure("window")
    .padding(SettingsCanvas.bleed)
}

@MainActor
private func emitSettings(
    _ writer: SpriteWriter,
    id: String,
    shot: (bitmap: Bitmap, rects: [String: CGRect]),
    state: [String: Any],
    text: [String: Any] = [:],
    rects: [String: CGRect] = [:],
    extra: [String: Any] = [:]
) throws {
    guard let window = shot.rects["window"] else { throw ToolError("\(id): window not measured") }
    var info: [String: Any] = ["state": state, "window": "SettingsView \(Int(SettingsView.size.width))x\(Int(SettingsView.size.height)) in WindowFrame (traffic lights, 12 pt corners, two shadows)"]
    if !text.isEmpty { info["text"] = text }
    for (key, value) in extra { info[key] = value }
    try writer.emit(id: id, canvas: shot.bitmap, scale: 3, content: window, anchor: .topLeft, group: "settings",
                    extra: info, rects: rects)
}

@MainActor
private func settingsSprite(_ writer: SpriteWriter, id: String, page: SettingsPage, state: [String: Any]) throws {
    let film = FilmContext()
    let shot = snapshot(settingsScene(film, page: page), size: SettingsCanvas.size, scale: 3)
    try emitSettings(writer, id: id, shot: shot, state: state)
}

@MainActor
private func historySprite(_ writer: SpriteWriter, id: String, query: String) throws {
    let film = FilmContext()
    var caret: CGRect?
    let shot = snapshot(settingsScene(film, page: .history), size: SettingsCanvas.size, scale: 3) { host in
        // HistoryPage keeps its query in @State, so type it into the search field like a user.
        guard let field = host.hosting.firstDescendant(of: NSTextField.self, where: { $0.isEditable }) else {
            writer.warn("\(id): no search field found")
            return
        }
        host.window.makeKey()
        host.window.makeFirstResponder(field)
        if !query.isEmpty { field.currentEditor()?.insertText(query) }
        host.wait(0.3)
        if let editor = field.currentEditor() as? NSTextView { caret = caretRect(of: editor, in: host) }
        host.window.makeFirstResponder(nil)
        host.wait(0.2)
    }
    let rows = film.history.search(query).count
    let expected = ["": 4, "o": 4, "oa": 2, "oat": 1][query]
    if let expected, expected != rows { writer.warn("\(id): \(rows) rows, the spec expects \(expected)") }
    var rects: [String: CGRect] = [:]
    if let caret { rects["caret_rect_pt"] = caret }
    try emitSettings(writer, id: id, shot: shot,
                     state: ["page": "history", "query": query, "retention": film.preferences.historyRetention.title],
                     text: ["rows": rows, "query": query, "group": "TODAY",
                            "entries": film.history.search(query).map { "\($0.appName ?? "") · \($0.text)" }],
                     rects: rects,
                     extra: ["caret_note": "The search field isn't focused in the sprite; caret_rect_pt is the end of the query."])
}

@MainActor
private func vocabularySprite(_ writer: SpriteWriter, id: String, vocabulary: String) throws {
    let preferences = filmPreferences()
    preferences.vocabulary = vocabulary
    let film = FilmContext(preferences: preferences)
    var caret: CGRect?
    var focused = false
    let shot = snapshot(settingsScene(film, page: .language), size: SettingsCanvas.size, scale: 3) { host in
        // Focus the vocabulary editor (accent border, as while typing) but hide its caret: the stage draws it.
        guard let textView = host.hosting.firstDescendant(of: NSTextView.self, where: { $0.isEditable }) else {
            writer.warn("\(id): no vocabulary editor found")
            return
        }
        host.window.makeKey()
        textView.insertionPointColor = .clear
        focused = host.window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        host.wait(0.3)
        caret = caretRect(of: textView, in: host)
    }
    let words = preferences.vocabularyWords.count
    let counter = words == 1 ? "1 word" : "\(words) words"
    let expected = vocabulary.hasSuffix(", S") || vocabulary.contains("Sw") ? "5 words" : "4 words"
    if counter != expected { writer.warn("\(id): counter \(counter), expected \(expected)") }
    var rects: [String: CGRect] = [:]
    if let caret { rects["caret_rect_pt"] = caret }
    try emitSettings(writer, id: id, shot: shot,
                     state: ["page": "language", "vocabulary": vocabulary, "editor_focused": focused],
                     text: ["counter": counter, "speaking": preferences.language.displayName,
                            "pinned": preferences.pinnedLanguages.enumerated().map { "⌘\($0.offset + 1) \($0.element.displayName)" }],
                     rects: rects,
                     extra: ["caret_note": "Editor focused (accent border) with its caret hidden; caret_rect_pt is the end of the text."])
}

@MainActor
private func shortcutSprite(_ writer: SpriteWriter, id: String, hotkey: Hotkey, recording: Bool) throws {
    let preferences = filmPreferences()
    preferences.pushToTalkHotkey = hotkey
    let film = FilmContext(preferences: preferences)
    if recording { film.context.recorder.start(.pushToTalk) }
    let shot = snapshot(settingsScene(film, page: .shortcut), size: SettingsCanvas.size, scale: 3)
    if recording { film.context.recorder.stop() }
    try emitSettings(writer, id: id, shot: shot,
                     state: ["page": "shortcut", "hotkey": hotkey.keycaps.joined(separator: " "), "recording": recording,
                             "trigger_mode": preferences.triggerMode.rawValue],
                     text: ["keycaps": hotkey.keycaps])
}

// MARK: Small pieces

@MainActor
private func keycapSprite(_ writer: SpriteWriter, id: String, label: String) throws {
    let scale = 4
    let bleed: CGFloat = 8
    let shot = snapshot(
        Keycap(label: label).measure("keycap").padding(bleed),
        size: CGSize(width: 120, height: 44),
        scale: CGFloat(scale),
        settle: 0.3
    )
    guard let keycap = shot.rects["keycap"] else { throw ToolError("keycap not measured") }
    try writer.emit(id: id, canvas: shot.bitmap, scale: scale, content: keycap, anchor: .center, group: "keycap",
                    extra: ["state": ["label": label], "note": "Keycap(label:) non-compact; content_rect excludes the 1.5 pt bottom edge shadow"])
}

@MainActor
private func glyphSprite(_ writer: SpriteWriter, id: String, symbol: String, size: CGFloat, weight: Font.Weight) throws {
    let scale = 4
    let shot = snapshot(
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white)
            .measure("glyph")
            .padding(8),
        size: CGSize(width: 56, height: 40),
        scale: CGFloat(scale),
        settle: 0.3
    )
    guard let glyph = shot.rects["glyph"] else { throw ToolError("glyph not measured") }
    try writer.emit(id: id, canvas: shot.bitmap, scale: scale, content: glyph, anchor: .center, group: "glyph",
                    extra: ["state": ["symbol": symbol, "point_size": size, "weight": weight == .regular ? "regular" : "medium"],
                            "note": "content_rect_pt is the symbol's layout box at menu-bar size (StoreMenuBar); centre it on the menu bar's midline"])
}

@MainActor
private func statusItemSprite(_ writer: SpriteWriter, id: String, image: NSImage, title: String?, state: [String: Any]) throws {
    let scale = 4
    let shot = snapshot(
        StatusItemContent(image: image, title: title).measure("item").padding(8),
        size: CGSize(width: 90, height: 36),
        scale: CGFloat(scale),
        settle: 0.3
    )
    guard let item = shot.rects["item"] else { throw ToolError("status item not measured") }
    try writer.emit(id: id, canvas: shot.bitmap, scale: scale, content: item, anchor: .center, group: "statusitem",
                    extra: ["state": state, "extra": true,
                            "note": "StatusIcons image + \" \" + title in monospacedDigitSystemFont 11 semibold, white, no highlight. The real NSStatusBarButton adds its own padding."])
}

@MainActor
private func iconSprite(_ writer: SpriteWriter) throws {
    let source = URL(fileURLWithPath: "Icon.png")
    let target = writer.folder.appendingPathComponent("icon_app.png")
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.copyItem(at: source, to: target)
    guard let image = NSImage(contentsOf: target)?.representations.first else { throw ToolError("Icon.png unreadable") }
    let w = image.pixelsWide, h = image.pixelsHigh
    let entry: [String: Any] = [
        "id": "icon_app", "file": "icon_app.png", "group": "icon", "scale": 1,
        "size_px": [w, h], "size_pt": [w, h], "content_rect_pt": [0, 0, w, h],
        "anchor": "center", "anchor_pt": [Double(w) / 2, Double(h) / 2],
        "note": "Byte-for-byte copy of Icon.png at the repo root (no re-encode)",
    ]
    writer.record(entry)
    var sidecar = entry
    sidecar.removeValue(forKey: "note"); sidecar.removeValue(forKey: "group"); sidecar.removeValue(forKey: "file")
    try writeJSON(sidecar, to: writer.folder.appendingPathComponent("icon_app.json"))
    print("  icon_app  \(w)x\(h) px (copied)")
}

// MARK: Command

@MainActor
func runSprites(_ args: Arguments) throws {
    let folder = URL(fileURLWithPath: args.value("--out") ?? "video/build/sprites")
    let only = args.value("--only").map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
    let jobs = spriteJobs()
    if args.flag("--list") {
        for job in jobs { print("\(job.id)\t\(job.group)") }
        return
    }
    let writer = try SpriteWriter(folder: folder)
    let selected = jobs.filter { job in
        guard let only else { return true }
        return only.contains(job.id) || only.contains(where: { $0.hasSuffix("*") && job.id.hasPrefix($0.dropLast()) }) || only.contains(job.group)
    }
    if selected.isEmpty { throw ToolError("No sprite matches --only \(args.value("--only") ?? "")") }
    print("Rendering \(selected.count) sprites into \(folder.path)")
    let start = Date()
    for job in selected {
        try job.run(writer)
    }
    try writer.writeManifest(merging: only != nil)
    print(String(format: "done in %.1f s", Date().timeIntervalSince(start)))
    if !writer.warnings.isEmpty {
        print("\(writer.warnings.count) warning(s):")
        for warning in writer.warnings { print("  - \(warning)") }
    }
}
