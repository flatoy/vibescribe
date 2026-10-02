// Renders the Mac App Store screenshots from the app's real SwiftUI views with sample data.
// Usage: swift run VibeScribeScreenshots --appstore [output-folder]   (default: appstore/screenshots/en-US)
//
// Writes six 2880×1800 opaque sRGB PNGs (the only files to upload), and 1280×800 JPEG previews in
// .build-shots/appstore-previews, outside appstore/screenshots so they're never uploaded by mistake.
// Everything VibeScribe draws (overlay, language picker, settings pages) is the real view, enlarged by
// rendering at a higher pixel density. The menu bar and its status item are SwiftUI replicas, and the
// other apps' windows are generic stand-ins.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import VibeScribeCore

// MARK: Layout

private enum Store {
    /// 1440×900 pt at 2× is the 2880×1800 App Store size.
    static let canvas = CGSize(width: 1440, height: 900)
    static let scale: CGFloat = 2
    static let preview = CGSize(width: 1280, height: 800)
    static let previewFolder = ".build-shots/appstore-previews"

    static let menuBarHeight: CGFloat = 28
    /// The copy block sits at the same place on every shot.
    static let copyLeft: CGFloat = 92
    static let copyTop: CGFloat = 284
    static let copyWidth: CGFloat = 470
    static let headlineSize: CGFloat = 72

    /// The right-hand stage the UI is composed in.
    static let stageMidX: CGFloat = 1000

    /// Every overlay pill: one zoom, centred under the menu bar like the app's overlay panel
    /// (10 pt below the menu bar, plus the view's 6 pt top padding).
    static let pillZoom: CGFloat = 1.6
    static let pillTop: CGFloat = menuBarHeight + 16
    /// The recording time shown by the pill and the menu bar item.
    static let recordingSeconds: TimeInterval = 7
}

// MARK: Rendering

private final class OffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Draws a view offscreen into an sRGB bitmap with transparency. `prepare` runs once the view is on
/// screen, to drive it like a user would (type a search, hover a row) before the capture.
@MainActor
private func snapshot<V: View>(
    _ view: V,
    size: CGSize,
    scale: CGFloat,
    prepare: ((NSWindow) -> Void)? = nil
) -> CGImage {
    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = OffscreenWindow(
        contentRect: CGRect(x: -8000, y: -8000, width: size.width, height: size.height),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.acceptsMouseMovedEvents = true
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    if let prepare {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        prepare(window)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int((size.width * scale).rounded()),
        pixelsHigh: Int((size.height * scale).rounded()),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    window.orderOut(nil)
    // The buffer holds the views' sRGB values unchanged (Theme colours read back exactly), so tag it as sRGB.
    return (rep.retagging(with: .sRGB) ?? rep).cgImage!
}

@MainActor
private func fittingSize<V: View>(_ view: V) -> CGSize {
    NSHostingView(rootView: view.fixedSize()).fittingSize
}

/// A view shown larger than life. `scaleEffect` would scale a 2× raster and blur the text, so the view is
/// rendered at the zoomed pixel density instead and placed as a bitmap at 1:1.
private struct Sprite: View {
    let image: CGImage
    /// Laid-out size on the canvas, without the bleed kept for shadows.
    let size: CGSize
    let bleed: CGFloat

    var body: some View {
        Image(decorative: image, scale: Store.scale)
            .frame(width: size.width + bleed * 2, height: size.height + bleed * 2)
            .padding(-bleed)
    }
}

/// Where to point at inside a sprite's view, in its own points from the top-left corner.
private struct SpriteDriver {
    var typing: String?
    var hover: CGPoint?
    /// Scrolls the first scroll view down this far.
    var scroll: CGFloat?
}

@MainActor
private func sprite<V: View>(
    _ view: V,
    size: CGSize? = nil,
    zoom: CGFloat,
    bleed: CGFloat = 70,
    driver: SpriteDriver? = nil
) -> Sprite {
    let natural = size ?? fittingSize(view)
    let padded = CGSize(width: natural.width + bleed * 2, height: natural.height + bleed * 2)
    let prepare: ((NSWindow) -> Void)? = driver.map { driver in
        { window in drive(window, driver, bleed: bleed, height: padded.height) }
    }
    let image = snapshot(
        view.frame(width: natural.width, height: natural.height).padding(bleed),
        size: padded,
        scale: Store.scale * zoom,
        prepare: prepare
    )
    return Sprite(
        image: image,
        size: CGSize(width: natural.width * zoom, height: natural.height * zoom),
        bleed: bleed * zoom
    )
}

/// Types into the first text field, moves the pointer over a point and scrolls, like a user would.
@MainActor
private func drive(_ window: NSWindow, _ driver: SpriteDriver, bleed: CGFloat, height: CGFloat) {
    if let typing = driver.typing, let field = window.contentView?.firstDescendant(of: NSTextField.self) {
        window.makeKey()
        window.makeFirstResponder(field)
        field.currentEditor()?.insertText(typing)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        // Drop the focus again, so no caret blinks in the shot.
        window.makeFirstResponder(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    if let hover = driver.hover {
        // Window coordinates have their origin at the bottom left.
        let location = NSPoint(x: bleed + hover.x, y: height - bleed - hover.y)
        for index in 0..<2 {
            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: location.x, y: location.y - CGFloat(index)),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )!
            // The hosting view tracks the pointer itself (an always-active tracking area), so hand it the
            // events directly; the window is offscreen, where AppKit wouldn't synthesise them.
            if index == 0 { window.contentView?.mouseEntered(with: event) }
            window.contentView?.mouseMoved(with: event)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }
    if let scroll = driver.scroll {
        guard let scrollView = window.contentView?.firstDescendant(of: NSScrollView.self) else {
            fatalError("No scroll view to scroll.")
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
}

extension NSView {
    fileprivate func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

/// Draws onto an opaque sRGB canvas, so the PNG has no alpha channel.
private func flattened(_ image: CGImage, size: CGSize? = nil) -> CGImage {
    let width = Int(size?.width ?? CGFloat(image.width))
    let height = Int(size?.height ?? CGFloat(image.height))
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(srgbRed: 0x2A / 255, green: 0x26 / 255, blue: 0x38 / 255, alpha: 1))
    context.fill(rect)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    return context.makeImage()!
}

private func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var properties: [CFString: Any] = [:]
    if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "Couldn’t write \(url.path)")
    print("wrote \(url.path)")
}

// MARK: Desktop pieces

/// The menu bar across the top of every shot, with a replica of VibeScribe's status item.
private struct StoreMenuBar: View {
    var app: String
    var menus: [String]
    var item: StatusItemGlyph
    var wifi = "wifi"

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "apple.logo").font(.system(size: 14)).padding(.trailing, 21)
            Text(app).font(.system(size: 13, weight: .bold)).padding(.trailing, 19)
            ForEach(menus, id: \.self) { Text($0).padding(.trailing, 19) }
            Spacer()
            item.padding(.trailing, 14)
            Image(systemName: wifi).padding(.trailing, 16)
            Image(systemName: "battery.75percent").padding(.trailing, 16)
            // 24-hour, like the times in the app's history.
            Text("Thu 14:02")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(width: Store.canvas.width, height: Store.menuBarHeight)
        .background(Color(hex: 0x14121E).opacity(0.38))
    }
}

/// Eyebrow, headline and subhead, in the same place on every shot.
private struct Copy {
    var eyebrow: String
    var lines: [String]
    /// The line drawn in the spectrum gradient.
    var accent: Int
    var subhead: String
}

private struct CopyBlock: View {
    var copy: Copy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                SpectrumBars(mode: .still, barWidth: 3, spacing: 2.2, height: 17)
                Text(copy.eyebrow)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.62))
            }
            .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: -Store.headlineSize * 0.2) {
                ForEach(Array(copy.lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: Store.headlineSize, weight: .bold))
                        .tracking(-Store.headlineSize * 0.028)
                        .foregroundStyle(index == copy.accent ? AnyShapeStyle(Theme.spectrumGradient) : AnyShapeStyle(.white))
                        .fixedSize()
                }
            }
            .padding(.leading, -3)
            Text(copy.subhead)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white.opacity(0.74))
                .lineSpacing(5)
                .frame(width: Store.copyWidth - 30, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
        }
        .frame(width: Store.copyWidth, alignment: .leading)
    }
}

/// One App Store screenshot: wallpaper, menu bar, copy on the left, the scene on the right.
private struct StoreShot<Scene: View>: View {
    var menuBar: StoreMenuBar
    var copy: Copy
    @ViewBuilder var scene: Scene

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            scene
            CopyBlock(copy: copy).offset(x: Store.copyLeft, y: Store.copyTop)
            menuBar
        }
        .frame(width: Store.canvas.width, height: Store.canvas.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Places a fixed-size view by its top-left corner on the canvas.
    fileprivate func at(_ x: CGFloat, _ y: CGFloat) -> some View {
        offset(x: x, y: y)
    }

    /// The edge and two-layer shadow of a macOS window, as `WindowFrame` draws it.
    fileprivate func windowChrome() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: Color(hex: 0x28144A).opacity(0.45), radius: 30, y: 24)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
    }
}

/// The overlay pill, at the shared zoom and position.
private struct PlacedPill: View {
    var pill: Sprite

    var body: some View {
        pill.at(Store.canvas.width / 2 - pill.size.width / 2, Store.pillTop)
    }
}

// MARK: Cropped settings pages

/// A piece of the settings window: a slice of a real page on the window surface, with the page title
/// row on top if there is one (15 pt semibold, 40 pt tall, as in the window).
private struct SettingsCrop<Page: View>: View {
    var width: CGFloat
    var title: String?
    /// Where the slice starts and how tall it is, in page points.
    var top: CGFloat = 0
    var height: CGFloat
    /// Plain window surface above and below the slice, so it doesn't start or end on a cut.
    var padTop: CGFloat = 0
    var padBottom: CGFloat = 0
    var pageHeight: CGFloat = SettingsView.size.height - 40
    @ViewBuilder var page: Page

    var size: CGSize {
        CGSize(width: width, height: (title == nil ? 0 : 40) + padTop + height + padBottom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 40)
                    .padding(.horizontal, 24)
            }
            page
                .frame(width: width, height: pageHeight)
                .offset(y: -top)
                .frame(width: width, height: height, alignment: .top)
                .clipped()
                .padding(.top, padTop)
                .padding(.bottom, padBottom)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .spectrumWindowBackground()
        .windowChrome()
    }
}

/// The arrow pointer, scaled like the sprite it sits on.
private struct Pointer: View {
    var zoom: CGFloat

    var body: some View {
        let cursor = NSCursor.arrow
        Image(nsImage: cursor.image)
            .resizable()
            .interpolation(.high)
            .frame(width: cursor.image.size.width * zoom, height: cursor.image.size.height * zoom)
    }

    /// The top-left corner that puts the pointer's hot spot on `tip`.
    static func origin(tip: CGPoint, zoom: CGFloat) -> CGPoint {
        let hotSpot = NSCursor.arrow.hotSpot
        return CGPoint(x: tip.x - hotSpot.x * zoom, y: tip.y - hotSpot.y * zoom)
    }
}

// MARK: Other apps (generic stand-ins)

private enum Mock {
    static let window = Color(hex: 0x1F1F22)
    static let titleBar = Color(hex: 0x2A2A2E)
    static let text = Color.white.opacity(0.9)
    static let dim = Color.white.opacity(0.45)
    static let caret = Theme.spectrum[1]
}

/// Window buttons: coloured in the front window, grey in windows behind it.
private struct StoreTrafficLights: View {
    var isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { hex in
                Circle()
                    .fill(isActive ? Color(hex: hex) : Color.white.opacity(0.2))
                    .overlay(Circle().strokeBorder(.black.opacity(isActive ? 0.12 : 0), lineWidth: 0.5))
            }
        }
        .frame(width: 52, height: 12)
    }
}

private struct MockWindow<Content: View>: View {
    var title: String
    var size: CGSize
    var titleBarHeight: CGFloat = 44
    var isActive = true
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.82 : 0.45))
                HStack {
                    StoreTrafficLights(isActive: isActive)
                    Spacer()
                    trailing
                }
                .padding(.leading, 20)
                .padding(.trailing, 16)
            }
            .frame(maxWidth: .infinity)
            .frame(height: titleBarHeight)
            .background(Mock.titleBar)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Mock.window)
        .frame(width: size.width, height: size.height)
        .windowChrome()
    }
}

private struct MailCompose: View {
    static let size = CGSize(width: 780, height: 444)

    var body: some View {
        MockWindow(
            title: "Re: Offsite agenda",
            size: Self.size,
            trailing: AnyView(
                Image(systemName: "paperplane").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            )
        ) {
            VStack(alignment: .leading, spacing: 0) {
                field("To:") {
                    Text("Priya Raman")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent.opacity(0.28)))
                }
                field("Cc:") { EmptyView() }
                field("Subject:") { Text("Re: Offsite agenda for Thursday").font(.system(size: 14)) }
                VStack(alignment: .leading, spacing: 18) {
                    Text("Hi Priya,")
                    Text("Thanks for pulling the numbers together so quickly. I went through the deck this morning and it reads really well, so let’s go with your version on Thursday.")
                        .fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(Mock.caret).frame(width: 2, height: 21)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On Wednesday, Priya Raman wrote:")
                        Text("Here’s the updated deck with the Q3 numbers. Could you check the agenda before I send it to everyone?")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Mock.dim)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) { Capsule().fill(Theme.accent.opacity(0.6)).frame(width: 2.5) }
                    .padding(.top, 6)
                }
                .font(.system(size: 16))
                .lineSpacing(6)
                .foregroundStyle(Mock.text)
                .padding(.horizontal, 26)
                .padding(.top, 22)
            }
        }
    }

    private func field<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 14)).foregroundStyle(Mock.dim)
            value().foregroundStyle(Mock.text)
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(height: 42)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1).padding(.horizontal, 18) }
    }
}

/// A chat window in the background. Its lower part, with the message field, sits behind the terminal.
private struct ChatWindow: View {
    static let size = CGSize(width: 540, height: 360)

    var body: some View {
        MockWindow(title: "Lena Fischer", size: Self.size, isActive: false) {
            VStack(alignment: .leading, spacing: 12) {
                bubble("Morning! Did you get a chance to look at the onboarding copy?", mine: false)
                bubble("Yes, just now. It reads well! I left a few notes on the second screen.", mine: true)
                bubble("Perfect, thanks!", mine: false)
                Spacer(minLength: 0)
                Text("Message")
                    .font(.system(size: 14))
                    .foregroundStyle(Mock.dim)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .background(Capsule().strokeBorder(Theme.hairlineStrong))
            }
            .padding(18)
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 70) }
            Text(text)
                .font(.system(size: 14.5))
                .lineSpacing(3)
                .foregroundStyle(.white.opacity(mine ? 1 : 0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(mine ? AnyShapeStyle(Theme.primaryFill) : AnyShapeStyle(Color(hex: 0x37373D)))
                )
                .fixedSize(horizontal: false, vertical: true)
            if !mine { Spacer(minLength: 70) }
        }
    }
}

private struct TerminalWindow: View {
    static let size = CGSize(width: 760, height: 330)
    var prompt: String

    var body: some View {
        MockWindow(title: "trailhead — zsh", size: Self.size, titleBarHeight: 40) {
            VStack(alignment: .leading, spacing: 5) {
                (Text("~/dev/trailhead").foregroundStyle(Theme.spectrum[0]) + Text(" on ").foregroundStyle(Mock.dim) + Text("main").foregroundStyle(Theme.spectrum[3]))
                Text("❯ git pull").foregroundStyle(Mock.text)
                Text("Already up to date.").foregroundStyle(Mock.dim)
                Text("❯ agent").foregroundStyle(Mock.text).padding(.top, 8)
                Text("Coding assistant · describe the change, ⏎ to send").foregroundStyle(Mock.dim)
                (Text("› ").foregroundStyle(Theme.spectrum[2]) + Text(prompt).foregroundStyle(.white) + Text("█").foregroundStyle(.white.opacity(0.75)))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.spectrum[2].opacity(0.55), lineWidth: 1.2))
                    .padding(.top, 12)
            }
            .font(.system(size: 14, design: .monospaced))
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }
}

/// A plain note: a heading and paragraphs, with an optional caret after the last one.
private struct NoteWindow: View {
    var size: CGSize
    var isActive = true
    var heading: String
    var paragraphs: [Text]
    var caret = false
    /// Darkened, to keep the eye on what floats above it.
    var dimmed = false

    var body: some View {
        MockWindow(title: "Notes", size: size, isActive: isActive) {
            VStack(alignment: .leading, spacing: 14) {
                Text(heading).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                    (index == paragraphs.count - 1 && caret ? paragraph + Text("▏").foregroundStyle(Mock.caret) : paragraph)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 16))
            .lineSpacing(6)
            .foregroundStyle(Mock.text)
            .padding(.horizontal, 30)
            .padding(.top, 26)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(dimmed ? 0.38 : 0)))
    }
}

// MARK: Sample data

@MainActor
private func language(_ code: String) -> WhisperLanguage {
    WhisperLanguage(rawValue: code)!
}

private let terminalPrompt = "Add retry logic to the photo upload client. Use exponential backoff starting at half a second, cap it at five attempts and show a friendly error after the last one. Then write unit tests for the timeout, offline and server error cases."

private let vocabulary = "Trailhead, Priya Raman, Lena Fischer, Marcus Oyelaran, Kubernetes, SwiftUI, OKRs"

private let vocabularyNote = "Priya Raman owns the SwiftUI onboarding, Lena Fischer moves the sync service to Kubernetes, and Marcus Oyelaran drafts the Trailhead OKRs before Friday."

/// The search typed into History, matching three of the entries below.
private let historyQuery = "offsite"

@MainActor
private func storeSample() -> Sample {
    let sample = Sample()
    let preferences = sample.preferences
    preferences.pinnedLanguages = [.automatic, .english, language("es")]
    for code in pickerRecents.reversed() { preferences.select(language(code)) }
    preferences.language = .automatic
    preferences.historyRetention = .forever
    preferences.vocabulary = vocabulary

    let now = Date()
    func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }
    sample.history.simulate([
        HistoryEntry(date: at(14, 2), text: "One change for the offsite: could we move the roadmap review to after lunch? Then the agenda is ready to send.", languageCode: "en", duration: 7, appName: "Mail"),
        HistoryEntry(date: at(14, 1), text: terminalPrompt, languageCode: "en", duration: 14, appName: "Terminal"),
        HistoryEntry(date: at(11, 20), text: "Offsite dinner: book a table for eight near the hotel, and ask whether they can do a vegetarian menu.", languageCode: "en", duration: 6, appName: "Notes"),
        HistoryEntry(date: at(10, 20), text: "¿Podemos mover la reunión al jueves a las diez? El miércoles no me viene bien.", languageCode: "es", duration: 5, appName: "Mail"),
        HistoryEntry(date: at(17, 48, daysAgo: 1), text: "Can you book the train to the offsite for both of us? Marcus asked whether we still need a ride from the station.", languageCode: "en", duration: 7, appName: "Messages"),
        HistoryEntry(date: at(16, 5, daysAgo: 1), text: "Can you book a table for four on Friday at seven? Ask if they have something by the window.", languageCode: "en", duration: 5, appName: "Messages"),
    ])

    sample.models.setup(for: .largeV3).simulate(.ready)
    sample.models.setup(for: .largeV3Turbo).simulate(.notDownloaded(0, 648_432_373))
    return sample
}

/// Recently used languages in the picker, most recent first.
private let pickerRecents = ["ja", "hi", "ar"]

/// The overlay pill at the shared zoom.
@MainActor
private func pillSprite(_ phase: OverlayPhase, level: Float = 0.85) -> Sprite {
    for _ in 0..<5 {
        let model = OverlayModel(level: LevelMeter())
        model.languageBadge = "EN"
        // The pill's timer ticks on whole seconds after startedAt. Start the clock so the second we want
        // ticks 0.3 s before the capture, which comes at least 0.6 s after the view appears.
        let startedAt = Date().addingTimeInterval(-(Store.recordingSeconds - 0.3))
        switch phase {
        case .listening(let handsFree): model.showListening(handsFree: handsFree, startedAt: startedAt)
        case .transcribing: model.showTranscribing()
        case .result(let result): model.show(result, for: 120)
        case .hidden: break
        }
        let pill = sprite(OverlayPill(phase: phase, model: model, level: level), zoom: Store.pillZoom, bleed: 40)
        // A slow capture could have passed the next tick; then the timer would read a second more.
        guard case .listening = phase, Date().timeIntervalSince(startedAt) >= Store.recordingSeconds + 1 else { return pill }
        print("The pill’s timer passed \(Format.duration(Store.recordingSeconds)) before the capture; rendering it again.")
    }
    fatalError("Couldn’t capture the pill at \(Format.duration(Store.recordingSeconds)).")
}

private let vibeScribeMenus = ["Edit", "Window"]
private let idleItem = StatusItemGlyph(recording: false, title: "AUTO")
private let recordingItem = StatusItemGlyph(recording: true, level: 0.8, title: Format.duration(Store.recordingSeconds))

// MARK: Shots

@MainActor
private func heroShot() -> some View {
    let pill = pillSprite(.listening(handsFree: false))
    let window = MailCompose.size
    return StoreShot(
        menuBar: StoreMenuBar(
            app: "Mail",
            menus: ["File", "Edit", "View", "Mailbox", "Message", "Format", "Window", "Help"],
            item: recordingItem
        ),
        copy: Copy(
            eyebrow: "PUSH-TO-TALK DICTATION",
            lines: ["Hold a key.", "Speak.", "Done."],
            accent: 2,
            subhead: "Hold Right ⌥ and talk. Let go, and your words appear right where you were typing."
        )
    ) {
        MailCompose().at(Store.stageMidX - window.width / 2, 236)
        PlacedPill(pill: pill)
    }
}

@MainActor
private func anyAppShot() -> some View {
    let words = FinalTranscript(text: terminalPrompt, languageCode: "en", duration: 14).wordCount
    let pill = pillSprite(.result(.pasted(words: words)))
    let terminal = TerminalWindow.size
    let terminalX = 1385 - terminal.width
    let terminalY: CGFloat = 470
    return StoreShot(
        menuBar: StoreMenuBar(app: "Terminal", menus: ["Shell", "Edit", "View", "Window", "Help"], item: idleItem),
        copy: Copy(
            eyebrow: "PASTES FOR YOU",
            lines: ["Works in", "any app."],
            accent: 1,
            subhead: "Your words are pasted right where your cursor is: email, chat, notes, even the terminal."
        )
    ) {
        // The terminal covers the chat window's whole width below its bubbles.
        ChatWindow().at(terminalX + 40, terminalY - 290)
        TerminalWindow(prompt: terminalPrompt).at(terminalX, terminalY)
        PlacedPill(pill: pill)
    }
}

@MainActor
private func privacyShot(_ sample: Sample) -> some View {
    // The active model's group and nothing below it: the page has 4 pt of top padding, the group is 182 pt tall.
    let crop = SettingsCrop(width: 470, title: SettingsPage.model.title, height: 186, padBottom: 22) {
        ModelPage(context: sample.context)
    }
    let card = sprite(crop, size: crop.size, zoom: 1.6)
    return StoreShot(
        // Wi-Fi off: dictation works offline once the model is downloaded.
        menuBar: StoreMenuBar(app: "VibeScribe", menus: vibeScribeMenus, item: idleItem, wifi: "wifi.slash"),
        copy: Copy(
            eyebrow: "PRIVATE BY DESIGN",
            lines: ["Private.", "On-device.", "No account."],
            accent: 2,
            subhead: "Whisper runs right on your Mac. VibeScribe never sends your voice or words anywhere."
        )
    ) {
        card.at(1390 - card.size.width, 440 - card.size.height / 2)
    }
}

@MainActor
private func languagesShot(_ sample: Sample) -> some View {
    let model = LanguagePickerModel(preferences: sample.preferences)
    model.highlightIndex = 0
    let picker = sprite(
        LanguagePickerView(model: model).shadow(color: .black.opacity(0.55), radius: 22, y: 16),
        size: LanguagePickerView.size,
        zoom: 1.5,
        // A few points down, so the list ends on a whole row rather than through one.
        driver: SpriteDriver(scroll: 8)
    )
    let note = CGSize(width: 610, height: 470)
    return StoreShot(
        // The picker is a non-activating panel: Notes stays the active app, with its window in front.
        menuBar: StoreMenuBar(app: "Notes", menus: ["File", "Edit", "Format", "View", "Window", "Help"], item: idleItem),
        copy: Copy(
            eyebrow: "MULTILINGUAL",
            lines: ["Dictate in", "100 languages."],
            accent: 1,
            subhead: "Press ⌥⇧ anywhere to switch. Pin favorites to ⌘1–⌘3, or let Automatic work it out."
        )
    ) {
        // The note's text sits above the picker, so none of it shows through the glass.
        NoteWindow(
            size: note,
            heading: "Kyoto, day two",
            paragraphs: [
                Text("Fushimi Inari before the crowds, then lunch at Nishiki."),
                Text("清水寺には朝早く行くのがおすすめです。"),
            ],
            dimmed: true
        )
        .at(1390 - note.width, 64)
        picker.at(640, 262)
    }
}

@MainActor
private func historyShot(_ sample: Sample) -> some View {
    let zoom: CGFloat = 1.4
    let crop = SettingsCrop(width: 560, title: SettingsPage.history.title, height: 360) {
        HistoryPage(context: sample.context)
    }
    // On the right end of the first match's "Paste again" button, clear of its label. The buttons end at
    // the row's trailing padding (page 24 + row 12); the row starts below the title, search field and header.
    let pointer = CGPoint(x: crop.size.width - 24 - 12 - 9, y: 133)
    let panel = sprite(crop, size: crop.size, zoom: zoom, driver: SpriteDriver(typing: historyQuery, hover: pointer))
    let origin = CGPoint(x: 1388 - panel.size.width, y: 172)
    let arrow = Pointer.origin(tip: CGPoint(x: origin.x + pointer.x * zoom, y: origin.y + pointer.y * zoom), zoom: zoom)
    return StoreShot(
        menuBar: StoreMenuBar(app: "VibeScribe", menus: vibeScribeMenus, item: idleItem),
        copy: Copy(
            eyebrow: "TRANSCRIPT HISTORY",
            lines: ["Every word,", "saved."],
            accent: 1,
            subhead: "Search what you said, copy it, or paste it again. Kept only on this Mac, as long as you like."
        )
    ) {
        panel.at(origin.x, origin.y)
        Pointer(zoom: zoom).at(arrow.x, arrow.y)
    }
}

@MainActor
private func vocabularyShot(_ sample: Sample) -> some View {
    // The Language page from the Vocabulary label to the bottom of its group (page points 180–378).
    let crop = SettingsCrop(width: 460, top: 180, height: 198, padTop: 8, padBottom: 22) {
        LanguagePage(context: sample.context)
    }
    let card = sprite(crop, size: crop.size, zoom: 1.45)
    let note = CGSize(width: 660, height: 340)
    return StoreShot(
        menuBar: StoreMenuBar(app: "Notes", menus: ["File", "Edit", "Format", "View", "Window", "Help"], item: idleItem),
        copy: Copy(
            eyebrow: "CUSTOM VOCABULARY",
            lines: ["Names,", "spelled", "your way."],
            accent: 2,
            subhead: "Add the names and jargon you use. VibeScribe hands them to Whisper as spelling hints."
        )
    ) {
        NoteWindow(
            size: note,
            heading: "Trailhead launch",
            paragraphs: [Text("Owners for next week:"), Text(vocabularyNote)],
            caret: true
        )
        .at(1390 - note.width, 120)
        card.at(640, 400)
    }
}

// MARK: Main

@MainActor
func renderAppStoreShots(arguments: [String]) {
    // Sizes and dates follow the system region ("629,5 MB" in Norway). Relaunch once in en-US.
    if Locale.current.identifier != "en_US", !CommandLine.arguments.contains("-AppleLocale") {
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = Array(CommandLine.arguments.dropFirst()) + ["-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
        do {
            try process.run()
            process.waitUntilExit()
            exit(process.terminationStatus)
        } catch {
            print("Couldn’t relaunch in en-US (\(error.localizedDescription)); continuing with \(Locale.current.identifier).")
        }
    }

    let folder = arguments.first { !$0.hasPrefix("-") && $0 != "(en)" && $0 != "en_US" } ?? "appstore/screenshots/en-US"
    let output = URL(fileURLWithPath: folder)
    let previews = URL(fileURLWithPath: Store.previewFolder)
    let files = FileManager.default
    for directory in [output, previews] {
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Drop renders from earlier runs, in case a slug changed.
        for name in (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.range(of: #"^\d\d-.+\.(png|jpg)$"#, options: .regularExpression) != nil {
            try? files.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    let sample = storeSample()
    let shots: [(slug: String, view: () -> AnyView)] = [
        ("hold-to-talk", { AnyView(heroShot()) }),
        ("works-in-any-app", { AnyView(anyAppShot()) }),
        ("private-on-device", { AnyView(privacyShot(sample)) }),
        ("100-languages", { AnyView(languagesShot(sample)) }),
        ("transcript-history", { AnyView(historyShot(sample)) }),
        ("custom-vocabulary", { AnyView(vocabularyShot(sample)) }),
    ]
    for (index, shot) in shots.enumerated() {
        let name = String(format: "%02d-%@", index + 1, shot.slug)
        let image = flattened(snapshot(shot.view(), size: Store.canvas, scale: Store.scale))
        write(image, to: output.appendingPathComponent("\(name).png"), type: .png)
        let preview = flattened(image, size: CGSize(width: Store.preview.width, height: Store.preview.height))
        write(preview, to: previews.appendingPathComponent("\(name).jpg"), type: .jpeg, quality: 0.86)
    }
}

