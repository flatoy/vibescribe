import SwiftUI

// MARK: Buttons

struct SpectrumButtonStyle: ButtonStyle {
    enum Kind {
        case normal
        case primary
        case ghost
        case danger
    }

    var kind: Kind = .normal
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        SpectrumButton(configuration: configuration, kind: kind, large: large)
    }
}

private struct SpectrumButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: SpectrumButtonStyle.Kind
    let large: Bool

    @Environment(\.isEnabled) private var isEnabled

    private var radius: CGFloat { large ? 8 : 6 }

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, large ? 16 : 11)
            .frame(height: large ? 30 : 24)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: kind == .normal || kind == .primary ? .black.opacity(0.35) : .clear, radius: 0.5, y: 0.5)
            .focusRing(cornerRadius: radius)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .normal: return Theme.text
        case .primary: return .white
        case .ghost: return Theme.secondary
        case .danger: return Theme.bad
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch kind {
        case .normal:
            Theme.control
                .overlay(alignment: .top) { Color.white.opacity(0.12).frame(height: 0.5) }
                .brightness(pressed ? 0.06 : 0)
        case .primary:
            Theme.primaryFill.brightness(pressed ? -0.06 : 0)
        case .ghost, .danger:
            Color.white.opacity(pressed ? 0.08 : 0)
        }
    }
}

/// A keyboard focus ring that follows the control's own corner radius.
/// Pair with `.focusEffectDisabled()` on the window, which hides the square system ring.
private struct FocusRing: ViewModifier {
    var cornerRadius: CGFloat

    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.85), lineWidth: 2)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func focusRing(cornerRadius: CGFloat) -> some View {
        modifier(FocusRing(cornerRadius: cornerRadius))
    }
}

extension ButtonStyle where Self == SpectrumButtonStyle {
    static var spectrum: SpectrumButtonStyle { SpectrumButtonStyle() }
    static var spectrumPrimary: SpectrumButtonStyle { SpectrumButtonStyle(kind: .primary) }
    static var spectrumGhost: SpectrumButtonStyle { SpectrumButtonStyle(kind: .ghost) }
    static func spectrum(_ kind: SpectrumButtonStyle.Kind, large: Bool = false) -> SpectrumButtonStyle {
        SpectrumButtonStyle(kind: kind, large: large)
    }
}

// MARK: Keys

struct Keycap: View {
    var label: String
    var compact = false

    var body: some View {
        Text(label)
            .font(.system(size: compact ? 10 : 11.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, compact ? 4 : 6)
            .frame(minWidth: compact ? 17 : 22, minHeight: compact ? 17 : 21)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: 0x34343A))
                    .shadow(color: .black.opacity(0.45), radius: 0, y: 1.5)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            }
    }
}

struct KeycapRow: View {
    var labels: [String]
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Keycap(label: label, compact: compact)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.joined(separator: " "))
    }
}

// MARK: Segmented control

struct SpectrumSegmented<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isOn ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isOn ? Theme.segmentThumb : .clear)
                                .shadow(color: .black.opacity(isOn ? 0.35 : 0), radius: 1, y: 1)
                        )
                        .focusRing(cornerRadius: 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.segmentTrack))
    }
}

// MARK: Grouped rows

struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct GroupLabel: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.leading, 4)
            .padding(.bottom, -8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsRow<Accessory: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

struct RowDivider: View {
    var body: some View {
        Theme.hairline.frame(height: 1)
    }
}

// MARK: Status and small pieces

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

extension AppPhase {
    var color: Color {
        switch self {
        case .ready, .recording, .transcribing: return Theme.ok
        case .settingUp: return Theme.accent
        case .shortcutPaused: return Theme.tertiary
        case .attention(.modelFailed): return Theme.bad
        case .attention: return Theme.warn
        }
    }
}

/// Ten-segment input meter.
struct LevelSegments: View {
    var level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                let isOn = Float(index) < level * 10
                RoundedRectangle(cornerRadius: 1)
                    .fill(isOn ? color(index) : Color.white.opacity(0.12))
                    .frame(width: 4, height: 12)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func color(_ index: Int) -> Color {
        switch index {
        case 0..<4: return Theme.spectrum[0]
        case 4..<7: return Theme.spectrum[2]
        default: return Theme.spectrum[5]
        }
    }
}

struct Tag: View {
    var title: String
    var color: Color = Theme.ok

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.16)))
    }
}

struct WarningBanner<Actions: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Theme.warn.opacity(0.14), Theme.warn.opacity(0.06)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warn.opacity(0.3)))
    }
}

struct FieldBackground: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.hairlineStrong)
            )
    }
}

extension View {
    func fieldBackground(focused: Bool = false) -> some View {
        modifier(FieldBackground(focused: focused))
    }
}

/// A permission with its reason and a way to allow it.
struct PermissionCard: View {
    var systemImage: String
    var title: String
    var reason: String
    var status: PermissionStatus
    var isPrimary: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.iconWell))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.isGranted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ok)
            } else {
                Button(status == .notDetermined ? "Allow" : "Open Settings", action: action)
                    .buttonStyle(.spectrum(isPrimary ? .primary : .normal))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .opacity(status.isGranted || isPrimary ? 1 : 0.75)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func timeRemaining(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        if seconds < 50 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        return minutes <= 1 ? "about 1 min left" : "about \(minutes) min left"
    }
}
