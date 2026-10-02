// Offscreen rendering, pixel buffers, trimming and file output.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: Offscreen window

final class OffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Frames reported by `.measure(_:)`, in canvas points from the top-left corner.
struct MeasureKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Records this view's laid-out frame in the canvas under `name`.
    func measure(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MeasureKey.self, value: [name: proxy.frame(in: .named(Canvas.space))])
        })
    }
}

@MainActor
final class MeasureStore {
    static let shared = MeasureStore()
    var rects: [String: CGRect] = [:]
}

enum Canvas {
    static let space = "canvas"
}

/// A view hosted in a borderless, transparent, dark-appearance window far off screen, like the app's panels.
@MainActor
final class Host {
    let window: OffscreenWindow
    let hosting: NSHostingView<AnyView>
    let size: CGSize

    init<V: View>(_ view: V, size: CGSize, origin: CGPoint = CGPoint(x: -8000, y: -8000)) {
        self.size = size
        hosting = NSHostingView(rootView: Host.wrap(view, size: size))
        hosting.frame = CGRect(origin: .zero, size: size)
        window = OffscreenWindow(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
    }

    static func wrap<V: View>(_ view: V, size: CGSize) -> AnyView {
        AnyView(
            view
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .coordinateSpace(name: Canvas.space)
                .onPreferenceChange(MeasureKey.self) { rects in
                    MainActor.assumeIsolated { MeasureStore.shared.rects.merge(rects) { $1 } }
                }
                .environment(\.colorScheme, .dark)
        )
    }

    func replace<V: View>(_ view: V) {
        hosting.rootView = Host.wrap(view, size: size)
        hosting.layoutSubtreeIfNeeded()
    }

    func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func capture(scale: CGFloat) -> Bitmap {
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
        // The buffer holds the views' sRGB values unchanged (Theme colours read back exactly), so tag it sRGB,
        // as Tools/VibeScribeScreenshots/AppStoreShots.swift does.
        let image = (rep.retagging(with: .sRGB) ?? rep).cgImage!
        return Bitmap(image: image)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

/// Renders a view once: host, settle, optionally drive it, capture.
@MainActor
func snapshot<V: View>(
    _ view: V,
    size: CGSize,
    scale: CGFloat,
    settle: TimeInterval = 0.6,
    prepare: ((Host) -> Void)? = nil
) -> (bitmap: Bitmap, rects: [String: CGRect]) {
    MeasureStore.shared.rects = [:]
    let host = Host(view, size: size)
    if let prepare {
        host.wait(0.3)
        prepare(host)
    }
    host.wait(settle)
    let bitmap = host.capture(scale: scale)
    let rects = MeasureStore.shared.rects
    host.close()
    return (bitmap, rects)
}

// MARK: Pixels

/// Premultiplied RGBA, 8 bits per channel, sRGB, rows top to bottom.
struct Bitmap {
    var width: Int
    var height: Int
    var data: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        data = [UInt8](repeating: 0, count: width * height * 4)
    }

    init(image: CGImage) {
        self.init(width: image.width, height: image.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func cgImage() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    func alpha(_ x: Int, _ y: Int) -> UInt8 { data[index(x, y) + 3] }

    /// Smallest rectangle (in pixels) holding every pixel with alpha above `threshold`.
    func opaqueBounds(threshold: UInt8 = 0) -> PixelRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        data.withUnsafeBufferPointer { p in
            for y in 0..<height {
                let row = y * width * 4
                for x in 0..<width where p[row + x * 4 + 3] > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func cropped(_ rect: PixelRect) -> Bitmap {
        var out = Bitmap(width: rect.width, height: rect.height)
        for y in 0..<rect.height {
            let sy = y + rect.y
            guard sy >= 0, sy < height else { continue }
            for x in 0..<rect.width {
                let sx = x + rect.x
                guard sx >= 0, sx < width else { continue }
                let s = index(sx, sy), d = out.index(x, y)
                out.data[d] = data[s]
                out.data[d + 1] = data[s + 1]
                out.data[d + 2] = data[s + 2]
                out.data[d + 3] = data[s + 3]
            }
        }
        return out
    }

    /// Porter-Duff source-over of `top` with its top-left corner at (`x`, `y`), in premultiplied space.
    mutating func composite(_ top: Bitmap, atX ox: Int, y oy: Int) {
        for y in 0..<top.height {
            let dy = y + oy
            guard dy >= 0, dy < height else { continue }
            for x in 0..<top.width {
                let dx = x + ox
                guard dx >= 0, dx < width else { continue }
                let s = top.index(x, y)
                let sa = Int(top.data[s + 3])
                if sa == 0 { continue }
                let d = index(dx, dy)
                if sa == 255 {
                    data[d] = top.data[s]; data[d + 1] = top.data[s + 1]
                    data[d + 2] = top.data[s + 2]; data[d + 3] = 255
                    continue
                }
                let inv = 255 - sa
                for c in 0..<4 {
                    let value = Int(top.data[s + c]) + (Int(data[d + c]) * inv + 127) / 255
                    data[d + c] = UInt8(min(value, 255))
                }
            }
        }
    }

    /// Per-channel minimum. Removes a moving additive highlight (the shimmer) from several captures.
    static func minimum(_ images: [Bitmap]) -> Bitmap {
        var out = images[0]
        for image in images.dropFirst() {
            precondition(image.width == out.width && image.height == out.height)
            for i in 0..<out.data.count where image.data[i] < out.data[i] {
                out.data[i] = image.data[i]
            }
        }
        return out
    }

    /// Replaces a rectangle by interpolating, row by row, between the column just left of it and the
    /// column just right of it (premultiplied RGBA). Smooth gradients survive exactly.
    mutating func cleanPlate(_ rect: PixelRect) {
        let left = rect.x - 1
        let right = rect.x + rect.width
        precondition(left >= 0 && right < width)
        for y in rect.y..<(rect.y + rect.height) {
            let l = index(left, y), r = index(right, y)
            let span = Double(right - left)
            for x in rect.x..<(rect.x + rect.width) {
                let t = Double(x - left) / span
                let d = index(x, y)
                for c in 0..<4 {
                    let value = Double(data[l + c]) * (1 - t) + Double(data[r + c]) * t
                    data[d + c] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }
    }

    struct Difference {
        var maxDelta: Int
        var differingPixels: Int
        var pixelsOverTwo: Int
        var meanDelta: Double
        var total: Int
    }

    func difference(_ other: Bitmap, in rect: PixelRect? = nil) -> Difference {
        precondition(width == other.width && height == other.height, "size mismatch \(width)x\(height) vs \(other.width)x\(other.height)")
        let r = rect ?? PixelRect(x: 0, y: 0, width: width, height: height)
        var maxDelta = 0, differing = 0, overTwo = 0, sum = 0
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) {
                let i = index(x, y)
                var pixelMax = 0
                for c in 0..<4 {
                    let delta = abs(Int(data[i + c]) - Int(other.data[i + c]))
                    pixelMax = max(pixelMax, delta)
                    sum += delta
                }
                if pixelMax > 0 { differing += 1 }
                if pixelMax > 2 { overTwo += 1 }
                maxDelta = max(maxDelta, pixelMax)
            }
        }
        let total = r.width * r.height
        return Difference(maxDelta: maxDelta, differingPixels: differing, pixelsOverTwo: overTwo,
                          meanDelta: Double(sum) / Double(max(total * 4, 1)), total: total)
    }

    /// Whether any pixel on the outermost ring has alpha.
    var touchesEdge: Bool {
        for x in 0..<width where alpha(x, 0) > 0 || alpha(x, height - 1) > 0 { return true }
        for y in 0..<height where alpha(0, y) > 0 || alpha(width - 1, y) > 0 { return true }
        return false
    }

    func writePNG(to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage(), nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolError("Couldn’t write \(url.path)")
        }
    }
}

struct PixelRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    func union(_ other: PixelRect) -> PixelRect {
        let minX = min(x, other.x), minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width), maxY = max(y + height, other.y + other.height)
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Grows outward to whole points.
    func snappedToPoints(scale: Int, limitWidth: Int, limitHeight: Int) -> PixelRect {
        let x0 = (x / scale) * scale
        let y0 = (y / scale) * scale
        let x1 = min(((x + width + scale - 1) / scale) * scale, limitWidth)
        let y1 = min(((y + height + scale - 1) / scale) * scale, limitHeight)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: JSON

/// Rounds to 3 decimals, so the manifest reads cleanly.
func r3(_ value: CGFloat) -> Double { (Double(value) * 1000).rounded() / 1000 }

func rectJSON(_ rect: CGRect) -> [Double] {
    [r3(rect.origin.x), r3(rect.origin.y), r3(rect.width), r3(rect.height)]
}

func writeJSON(_ object: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (data + Data("\n".utf8)).write(to: url)
}

func ensureDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}
