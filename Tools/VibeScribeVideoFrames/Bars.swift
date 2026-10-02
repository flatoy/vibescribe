// The overlay's SpectrumBars with time injected, so frames are deterministic.
//
// SpectrumBars (Sources/VibeScribeCore/UI/Spectrum.swift) reads its time from a TimelineView, whose dates
// follow the wall clock and can't be stepped offscreen. ReplicaBars is the same body with the same
// arithmetic, fed a time and a level instead; `verify` renders both and diffs the pixels.

import AppKit
import SwiftUI
@testable import VibeScribeCore

enum BarsMath {
    /// Copied from SpectrumBars (main.swift checks the profile against SpectrumBars.profile at launch;
    /// speeds and phases are private there).
    static let profile: [CGFloat] = [0.34, 0.72, 0.48, 1.0, 0.56, 0.78, 0.34]
    static let speeds: [Double] = [7.9, 10.4, 6.9, 9.0, 7.6, 9.7, 6.6]
    static let phases: [Double] = [0.2, 1.9, 3.1, 0.8, 2.6, 4.2, 5.0]

    /// The TimelineView's refresh: `.animation(minimumInterval: 1.0 / 30.0)`.
    static let refreshRate: Double = 30

    enum Mode: Equatable {
        case live(Float)
        case breathing
        case thinking
        case still
        case flat
    }

    struct Frame: Equatable {
        var fractions: [CGFloat]
        var opacities: [Double]
    }

    /// `time` is `context.date.timeIntervalSinceReferenceDate` in the real view.
    static func frame(_ mode: Mode, time: TimeInterval) -> Frame {
        Frame(
            fractions: (0..<7).map { fraction($0, time, mode) },
            opacities: (0..<7).map { opacity($0, time, mode) }
        )
    }

    // The three functions below are copied verbatim from SpectrumBars (reduceMotion = false).

    private static func fraction(_ index: Int, _ time: TimeInterval, _ mode: Mode) -> CGFloat {
        let shape = profile[index]
        switch mode {
        case .live(let level):
            return liveFraction(index, time, level: CGFloat(level))
        case .breathing:
            return liveFraction(index, time, level: 0.6 + 0.3 * CGFloat(sin(time * 1.4)))
        case .thinking:
            let wave = max(0, sin(time * 4.4 - Double(index) * 0.55))
            return 0.22 + 0.42 * CGFloat(wave)
        case .still:
            return shape
        case .flat:
            return 0.2
        }
    }

    private static func liveFraction(_ index: Int, _ time: TimeInterval, level: CGFloat) -> CGFloat {
        let wobble = 0.72 + 0.28 * CGFloat(sin(time * speeds[index] + phases[index]))
        let idle = 0.03 * CGFloat(sin(time * 3 + phases[index]))
        return min(max(0.2 + idle + 0.8 * level * profile[index] * wobble, 0.18), 1)
    }

    private static func opacity(_ index: Int, _ time: TimeInterval, _ mode: Mode) -> Double {
        switch mode {
        case .thinking:
            return 0.45 + 0.55 * max(0, sin(time * 4.4 - Double(index) * 0.55))
        case .flat:
            return 0.35
        default:
            return 1
        }
    }

    /// The date a 30 Hz TimelineView entry would carry at `time`.
    static func quantized(_ time: TimeInterval, rate: Double = refreshRate) -> TimeInterval {
        rate > 0 ? (time * rate).rounded(.down) / rate : time
    }
}

/// SpectrumBars' body without the TimelineView.
struct ReplicaBars: View {
    var frame: BarsMath.Frame
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var height: CGFloat = 16
    var tint: Color?

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<7, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint ?? Theme.spectrum[index])
                    .frame(width: barWidth, height: max(barWidth, height * frame.fractions[index]))
                    .opacity(frame.opacities[index])
            }
        }
        .frame(height: height)
    }
}

/// Geometry of the bars inside the pill: padding leading 13, 33×16 pt, centred in the 34 pt height.
enum PillGeometry {
    static let height: CGFloat = 34
    static let barsOrigin = CGPoint(x: 13, y: 9)
    static let barsSize = CGSize(width: 33, height: 16)
    /// Margin kept around the bars in the bars layer, in points.
    static let barsMargin: CGFloat = 2
    static var barsLayerSize: CGSize {
        CGSize(width: barsSize.width + barsMargin * 2, height: barsSize.height + barsMargin * 2)
    }
}

/// The transcribing shimmer (OverlayPill.shimmer) at a given time, clipped to the pill like the real one.
struct ReplicaShimmer: View {
    var size: CGSize
    var time: TimeInterval

    var body: some View {
        let t = time.truncatingRemainder(dividingBy: 1.6) / 1.6
        LinearGradient(colors: [.clear, .white.opacity(0.1), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: size.width * 0.5, height: size.height)
            .offset(x: size.width * (1.5 * t - 0.5))
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Renders small views again and again in one window. A fresh rootView is laid out and given one
/// short run loop turn before each capture.
@MainActor
final class FrameRenderer {
    private let host: Host
    let scale: CGFloat

    init(size: CGSize, scale: CGFloat, origin: CGPoint = CGPoint(x: -9000, y: -8000)) {
        self.scale = scale
        host = Host(Color.clear, size: size, origin: origin)
        host.wait(0.2)
    }

    func render<V: View>(_ view: V) -> Bitmap {
        host.replace(view)
        host.hosting.needsDisplay = true
        host.wait(0.004)
        host.hosting.layoutSubtreeIfNeeded()
        return host.capture(scale: scale)
    }

    func close() { host.close() }
}

// MARK: Status item

/// The status item's content as MenuBarController.refreshButton() sets it: an image from StatusIcons
/// and " " + title in NSFont.monospacedDigitSystemFont(11, .semibold). Drawn white, as on a dark menu bar.
struct StatusItemContent: View {
    var image: NSImage
    var title: String?

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: image)
                .renderingMode(image.isTemplate ? .template : .original)
                .foregroundStyle(.white)
            if let title {
                Text(" " + title)
                    .font(Font(NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold) as CTFont))
                    .foregroundStyle(.white)
            }
        }
        .fixedSize()
    }
}
