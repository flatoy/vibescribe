import SwiftUI

enum OverlayResult: Equatable {
    case pasted(words: Int)
    case copied
    case noSpeech
    case cancelled
    /// The shortcut was pressed before the model finished loading.
    case loading(Double?)
    case microphoneOff
    case failed(String)
}

enum OverlayPhase: Equatable {
    case hidden
    case listening(handsFree: Bool)
    case transcribing
    case result(OverlayResult)
}

/// What the floating pill shows.
@MainActor
final class OverlayModel: ObservableObject {
    @Published private(set) var phase: OverlayPhase = .hidden
    /// Language code shown while transcribing, or `nil` for automatic.
    @Published var languageBadge: String?
    /// Keycaps for the hands-free stop hint.
    @Published var shortcutKeycaps: [String] = ["⌥"]
    @Published private(set) var startedAt = Date()

    let level: LevelMeter
    private var hideTask: Task<Void, Never>?

    init(level: LevelMeter) {
        self.level = level
    }

    func showListening(handsFree: Bool, startedAt: Date = Date()) {
        if case .listening = phase {} else { self.startedAt = startedAt }
        set(.listening(handsFree: handsFree))
    }

    func showTranscribing() {
        set(.transcribing)
    }

    /// Shows an outcome briefly, then hides.
    func show(_ result: OverlayResult, for duration: TimeInterval = 1.3) {
        set(.result(result))
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.set(.hidden)
        }
    }

    func hide() {
        set(.hidden)
    }

    private func set(_ phase: OverlayPhase) {
        hideTask?.cancel()
        hideTask = nil
        self.phase = phase
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var level: LevelMeter

    init(model: OverlayModel) {
        self.model = model
        self.level = model.level
    }

    var body: some View {
        VStack {
            if model.phase != .hidden {
                OverlayPill(phase: model.phase, model: model, level: level.level)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -12)),
                        removal: .opacity.combined(with: .offset(y: -8))
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: model.phase)
    }
}

struct OverlayPill: View {
    var phase: OverlayPhase
    @ObservedObject var model: OverlayModel
    var level: Float

    var body: some View {
        HStack(spacing: 10) {
            leading
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
            trailing
        }
        .padding(.leading, 13)
        .padding(.trailing, 14)
        .frame(height: 34)
        .background(Theme.glassBackground)
        .overlay(shimmer)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.glassBorder))
        .shadow(color: .black.opacity(0.4), radius: 11, y: 8)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch phase {
        case .hidden: return ""
        case .listening(let handsFree): return handsFree ? "Hands-free" : "Listening"
        case .transcribing: return "Transcribing"
        case .result(let result):
            switch result {
            case .pasted: return "Pasted"
            case .copied: return "Copied"
            case .noSpeech: return "No speech heard"
            case .cancelled: return "Cancelled"
            case .loading: return "Loading speech model"
            case .microphoneOff: return "Microphone access is off"
            case .failed: return "Couldn’t transcribe"
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .listening:
            SpectrumBars(mode: .live(level))
        case .transcribing:
            SpectrumBars(mode: .thinking)
        case .result(let result):
            switch result {
            case .pasted:
                Image(systemName: "checkmark").foregroundStyle(Theme.spectrum[0]).font(.system(size: 13, weight: .bold))
            case .copied:
                Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.spectrum[2]).font(.system(size: 12, weight: .semibold))
            case .noSpeech:
                SpectrumBars(mode: .flat, tint: .white)
            case .cancelled:
                SpectrumBars(mode: .still, tint: .white).opacity(0.35)
            case .loading(let progress):
                ProgressRing(progress: progress)
            case .microphoneOff, .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warn).font(.system(size: 12, weight: .semibold))
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .hidden:
            EmptyView()
        case .listening(let handsFree):
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                meta(Format.duration(context.date.timeIntervalSince(model.startedAt)))
            }
            if handsFree {
                separator
                HStack(spacing: 4) {
                    Text("Tap")
                    KeycapRow(labels: model.shortcutKeycaps, compact: true)
                    Text("to stop ·")
                    Keycap(label: "esc", compact: true)
                    Text("to cancel")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            }
        case .transcribing:
            if let badge = model.languageBadge {
                Text(badge.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
            }
        case .result(let result):
            switch result {
            case .pasted(let words):
                meta(words == 1 ? "1 word" : "\(words) words")
            case .copied:
                separator
                hint { Text("Press"); KeycapRow(labels: ["⌘", "V"], compact: true); Text("to paste") }
            case .noSpeech:
                separator
                hint { Text("Nothing pasted") }
            case .loading(let progress):
                if let progress { meta("\(Int(progress * 100))%") }
            case .microphoneOff:
                separator
                hint { Text("See menu bar") }
            case .failed:
                separator
                hint { Text("See Settings") }
            case .cancelled:
                EmptyView()
            }
        }
    }

    private func meta(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
    }

    private func hint<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4, content: content)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 14)
    }

    @ViewBuilder
    private var shimmer: some View {
        if phase == .transcribing {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.1), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.5)
                    .offset(x: proxy.size.width * (1.5 * t - 0.5))
                }
            }
            .allowsHitTesting(false)
        }
    }
}
