import SwiftUI

/// Column widths shared by the header and every row, so the numbers line up.
enum ModelColumns {
    static let size: CGFloat = 58
    static let speed: CGFloat = 40
    static let errors: CGFloat = 42
    static let spacing: CGFloat = 8
}

struct ModelIcon: View {
    let model: SpeechModelID
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: model.systemImage)
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(Theme.spectrumGradient)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Theme.hairline))
            .accessibilityHidden(true)
    }
}

/// Size, Speed and Errors, above the rows' numbers.
struct ModelColumnsHeader: View {
    let trailingWidth: CGFloat

    var body: some View {
        HStack(spacing: ModelColumns.spacing) {
            Spacer(minLength: 0)
            Text("Size").frame(width: ModelColumns.size, alignment: .trailing)
                .help("Download size")
            Text("Speed").frame(width: ModelColumns.speed, alignment: .trailing)
                .help("Seconds to transcribe a minute of speech on an M4 Pro")
            Text("Errors").frame(width: ModelColumns.errors, alignment: .trailing)
                .help("Share of words wrong across English test sets. Lower is better.")
            Color.clear.frame(width: trailingWidth, height: 1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.tertiary)
        .accessibilityHidden(true)
    }
}

/// One model: icon, name and traits, its numbers in columns, and whatever the surface puts last.
struct ModelSummaryRow<Trailing: View>: View {
    let model: SpeechModelID
    let size: Int64?
    let trailingWidth: CGFloat
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ModelIcon(model: model)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: ModelColumns.spacing) {
                    Text(model.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    ModelStats(model: model, size: size)
                    trailing.frame(width: trailingWidth, alignment: .trailing)
                }
                ModelTraits(model: model)
            }
        }
    }
}

/// The numbers for one model. The best value in each column is brighter.
private struct ModelStats: View {
    let model: SpeechModelID
    let size: Int64?

    var body: some View {
        let models = SpeechModelID.available
        HStack(spacing: ModelColumns.spacing) {
            stat(size.map(Format.bytes) ?? "–", width: ModelColumns.size, best: false)
            stat(Format.seconds(model.secondsPerMinute), width: ModelColumns.speed,
                 best: model.secondsPerMinute == models.map(\.secondsPerMinute).min())
            stat(String(format: "%.1f%%", model.wordErrorRate), width: ModelColumns.errors,
                 best: model.wordErrorRate == models.map(\.wordErrorRate).min())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(size.map(Format.bytes) ?? "Unknown size"), \(Format.seconds(model.secondsPerMinute)) per minute of speech, \(String(format: "%.1f", model.wordErrorRate)) percent word errors")
    }

    private func stat(_ value: String, width: CGFloat, best: Bool) -> some View {
        Text(value)
            .font(.system(size: 12, weight: best ? .semibold : .regular).monospacedDigit())
            .foregroundStyle(best ? Theme.text : Theme.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

/// Languages, punctuation and vocabulary, an icon and a word each.
private struct ModelTraits: View {
    let model: SpeechModelID

    var body: some View {
        HStack(spacing: 12) {
            trait("globe", model.languages, color: Theme.secondary)
            if model.punctuatesShortPhrases {
                trait("checkmark", "Punctuation", color: Theme.secondary)
            } else {
                trait("circle.lefthalf.filled", "Punctuation", color: Theme.warn)
                    .help("Short phrases often come out lowercase, without punctuation")
            }
            if model.supportsVocabulary {
                trait("checkmark", "Vocabulary", color: Theme.secondary)
                    .help("Spells the words in your vocabulary your way")
            } else {
                trait("xmark", "Vocabulary", color: Theme.tertiary)
                    .help("Doesn’t use your vocabulary")
            }
        }
        .font(.system(size: 11.5))
    }

    private func trait(_ systemImage: String, _ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
            Text(label).foregroundStyle(color == Theme.tertiary ? Theme.tertiary : Theme.secondary)
        }
        .fixedSize()
    }
}

/// A label, a bar and a short detail, with an optional control at the end. Stacked puts the bar on
/// its own line, for narrow places.
struct ModelProgressLine<Control: View>: View {
    let label: String
    let progress: Double
    let detail: String
    var stacked = false
    @ViewBuilder var control: Control

    var body: some View {
        if stacked {
            VStack(spacing: 7) {
                SpectrumMeter(progress: progress)
                HStack {
                    labelText
                    Spacer()
                    detailText
                }
            }
        } else {
            HStack(spacing: 10) {
                labelText
                SpectrumMeter(progress: progress)
                detailText
                control
            }
        }
    }

    private var labelText: some View {
        Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.secondary).fixedSize()
    }

    private var detailText: some View {
        Text(detail).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.tertiary).fixedSize()
    }
}

extension ModelProgressLine where Control == EmptyView {
    init(label: String, progress: Double, detail: String, stacked: Bool = false) {
        self.init(label: label, progress: progress, detail: detail, stacked: stacked) { EmptyView() }
    }
}

/// Estimated compile progress for a model, updated every second.
struct CompileProgressLine: View {
    @ObservedObject var models: SpeechModelLibrary
    let model: SpeechModelID
    var stacked = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let estimate = models.compileEstimate(for: model, now: context.date)
            ModelProgressLine(
                label: "Compiling",
                progress: estimate?.progress ?? 0,
                detail: Format.compileTimeLeft(estimate?.remaining),
                stacked: stacked
            )
        }
        .help("Core ML compiles each model for this Mac the first time it loads")
    }
}

struct ModelListFootnote: View {
    var compact = false

    var body: some View {
        Text(compact
             ? "Speeds measured on an M4 Pro."
             : "Speed: seconds per minute of speech on an M4 Pro. Errors: English test sets, lower is better.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
    }
}
