import SwiftUI

/// The icon's seven bars. Moves with the microphone, shimmers while transcribing.
struct SpectrumBars: View {
    enum Mode: Equatable {
        /// Follows a microphone level between 0 and 1.
        case live(Float)
        /// Gentle motion without a microphone, for the welcome screen.
        case breathing
        /// A wave passing through while the model works.
        case thinking
        /// The icon's resting shape.
        case still
        /// Low and dim: nothing was heard.
        case flat
    }

    static let profile: [CGFloat] = [0.34, 0.72, 0.48, 1.0, 0.56, 0.78, 0.34]
    private static let speeds: [Double] = [7.9, 10.4, 6.9, 9.0, 7.6, 9.7, 6.6]
    private static let phases: [Double] = [0.2, 1.9, 3.1, 0.8, 2.6, 4.2, 5.0]

    var mode: Mode
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var height: CGFloat = 16
    /// Draws every bar in one colour instead of the spectrum.
    var tint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAnimated: Bool {
        guard !reduceMotion else { return false }
        switch mode {
        case .live, .breathing, .thinking: return true
        case .still, .flat: return false
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint ?? Theme.spectrum[index])
                        .frame(width: barWidth, height: max(barWidth, height * fraction(index, time)))
                        .opacity(opacity(index, time))
                }
            }
            .frame(height: height)
        }
        .accessibilityHidden(true)
    }

    private func fraction(_ index: Int, _ time: TimeInterval) -> CGFloat {
        let shape = Self.profile[index]
        switch reduceMotion ? Mode.still : mode {
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

    private func liveFraction(_ index: Int, _ time: TimeInterval, level: CGFloat) -> CGFloat {
        let wobble = 0.72 + 0.28 * CGFloat(sin(time * Self.speeds[index] + Self.phases[index]))
        let idle = 0.03 * CGFloat(sin(time * 3 + Self.phases[index]))
        return min(max(0.2 + idle + 0.8 * level * Self.profile[index] * wobble, 0.18), 1)
    }

    private func opacity(_ index: Int, _ time: TimeInterval) -> Double {
        switch reduceMotion ? Mode.still : mode {
        case .thinking:
            return 0.45 + 0.55 * max(0, sin(time * 4.4 - Double(index) * 0.55))
        case .flat:
            return 0.35
        default:
            return 1
        }
    }
}

/// The download progress: the icon's bars fill left to right, bottom up.
struct FillWave: View {
    var progress: Double
    var paused = false
    /// Pulses when there is no percentage to show.
    var breathing = false
    var barWidth: CGFloat = 18
    var spacing: CGFloat = 10
    var height: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !breathing || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<7, id: \.self) { index in
                    let barHeight = height * SpectrumBars.profile[index]
                    let fill = min(max(progress * 7 - Double(index), 0), 1)
                    ZStack(alignment: .bottom) {
                        Capsule(style: .continuous).fill(Color.white.opacity(0.07))
                        Capsule(style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                        Rectangle()
                            .fill(Theme.spectrum[index])
                            .frame(height: barHeight * fill)
                            .saturation(paused ? 0.25 : 1)
                            .brightness(paused ? -0.2 : 0)
                            .opacity(breathing && !reduceMotion ? 0.72 + 0.28 * sin(time * 3.5 - Double(index) * 0.4) : 1)
                    }
                    .frame(width: barWidth, height: barHeight)
                    .clipShape(Capsule(style: .continuous))
                }
            }
            .frame(height: height)
        }
        .accessibilityElement()
        .accessibilityLabel("Speech model download")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// A thin progress bar that reveals the spectrum from the left.
struct SpectrumMeter: View {
    var progress: Double
    var height: CGFloat = 4
    var track = Color.white.opacity(0.08)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Theme.spectrumGradient
                    .frame(width: proxy.size.width)
                    .mask(alignment: .leading) {
                        Capsule().frame(width: proxy.size.width * min(max(progress, 0), 1))
                    }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// A small circular progress indicator. `nil` spins.
struct ProgressRing: View {
    var progress: Double?
    var size: CGFloat = 15
    var lineWidth: CGFloat = 3
    var color: Color = .white

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress.map { max(0.02, min($0, 1)) } ?? 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .rotationEffect(.degrees(progress == nil && spin ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            guard progress == nil else { return }
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}
