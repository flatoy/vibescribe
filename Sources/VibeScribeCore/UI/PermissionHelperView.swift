import SwiftUI
import UniformTypeIdentifiers

enum PermissionHelperKind: Equatable {
    case inputMonitoring
    case accessibility

    var title: String {
        switch self {
        case .inputMonitoring: return "Allow Input Monitoring"
        case .accessibility: return "Allow Accessibility"
        }
    }

    var reason: String {
        switch self {
        case .inputMonitoring: return "So the shortcut works in every app."
        case .accessibility: return "So VibeScribe can paste for you."
        }
    }
}

/// The floating card beside System Settings: drag the app into the list, or switch it on.
struct PermissionHelperView: View {
    var kind: PermissionHelperKind
    var appURL: URL
    var onClose: () -> Void

    static let size = CGSize(width: 320, height: 172)

    @State private var bounce = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.spectrumGradient)
                    .offset(y: bounce ? -4 : 2)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bounce)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold))
                    Text(kind.reason).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("VibeScribe").font(.system(size: 13, weight: .semibold))
                    Text("Drag me into the list above").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "hand.draw")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            )
            .overlay(AppDragSource(url: appURL))
            .help("Drag VibeScribe into the list in System Settings")
            .accessibilityLabel("VibeScribe app. Drag into the list in System Settings.")

            Text("Already in the list? Turn its switch on. This card closes by itself once it’s allowed.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(Theme.glassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.glassBorder))
        .foregroundStyle(Theme.text)
        .environment(\.colorScheme, .dark)
        .onAppear { bounce = true }
    }
}
