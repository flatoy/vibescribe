import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case shortcut
    case language
    case history
    case model
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcut: return "Shortcut"
        case .language: return "Language"
        case .history: return "History"
        case .model: return "Speech model"
        case .about: return "About & diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .shortcut: return "keyboard"
        case .language: return "globe"
        case .history: return "clock"
        case .model: return "cube"
        case .about: return "doc.text"
        }
    }

    var color: Color {
        Theme.pageColors[SettingsPage.allCases.firstIndex(of: self) ?? 0]
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .general
}

struct SettingsView: View {
    let context: AppContext
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var status: AppStatus

    static let size = CGSize(width: 780, height: 560)

    init(context: AppContext, navigation: SettingsNavigation) {
        self.context = context
        self.navigation = navigation
        self.status = context.status
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(context: context, navigation: navigation)
                .frame(width: 200)
            Theme.hairline.frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.page.title)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 40)
                    .padding(.horizontal, 24)
                    .accessibilityAddTraits(.isHeader)
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: Self.size.width, minHeight: Self.size.height)
        .spectrumWindowBackground()
        .focusEffectDisabled()
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.page {
        case .general: GeneralPage(context: context)
        case .shortcut: ShortcutPage(context: context)
        case .language: LanguagePage(context: context)
        case .history: HistoryPage(context: context)
        case .model: ModelPage(context: context)
        case .about: AboutPage(context: context)
        }
    }
}

/// Scrollable page body with the shared padding and spacing.
struct SettingsPageBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 20)
        }
        .scrollIndicators(.automatic)
    }
}

private struct SettingsSidebar: View {
    let context: AppContext
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var status: AppStatus
    @ObservedObject private var models: SpeechModelLibrary
    @ObservedObject private var preferences: Preferences

    init(context: AppContext, navigation: SettingsNavigation) {
        self.context = context
        self.navigation = navigation
        self.status = context.status
        self.models = context.models
        self.preferences = context.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Color.clear.frame(height: 46)
            ForEach(SettingsPage.allCases) { page in
                Button {
                    navigation.page = page
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page.color))
                        Text(page.title).font(.system(size: 13))
                        Spacer(minLength: 0)
                        if let dot = warning(for: page) {
                            StatusDot(color: dot, size: 7)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(navigation.page == page ? Color.white.opacity(0.1) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(navigation.page == page ? .isSelected : [])
            }
            Spacer()
            statusCard
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func warning(for page: SettingsPage) -> Color? {
        switch page {
        case .general:
            return status.issues.contains { if case .modelFailed = $0 { return false } else { return true } }
                ? Theme.warn : nil
        case .model:
            return status.issues.contains { if case .modelFailed = $0 { return true } else { return false } }
                ? Theme.bad : nil
        default:
            return nil
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                StatusDot(color: status.phase.color)
                Text(status.phase.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Group {
                switch status.phase {
                case .settingUp(let progress):
                    Text(progress.map { "Downloading \(Int($0 * 100))%" } ?? "Preparing \(models.activeID.shortName)")
                default:
                    Text("\(models.activeID.shortName) · offline")
                }
                Text("\(preferences.pushToTalkHotkey.displayName) to dictate")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}
