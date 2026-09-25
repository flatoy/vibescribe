import SwiftUI

@MainActor
final class OnboardingNavigation: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome
        case permissions
        case model
        case practice
    }

    @Published var step: Step = .welcome
    @Published var practiceText = ""
    /// The first transcript dictated during the practice step.
    @Published var practiceResult: HistoryEntry?

    var onFinish: () -> Void = {}
}

struct OnboardingView: View {
    let context: AppContext
    @ObservedObject var navigation: OnboardingNavigation
    @ObservedObject private var permissions: Permissions
    @ObservedObject private var models: SpeechModelLibrary
    @ObservedObject private var preferences: Preferences

    static let size = CGSize(width: 512, height: 470)

    init(context: AppContext, navigation: OnboardingNavigation) {
        self.context = context
        self.navigation = navigation
        permissions = context.permissions
        models = context.models
        preferences = context.preferences
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40)
            Group {
                switch navigation.step {
                case .welcome: welcome
                case .permissions: permissionsStep
                case .model: ModelStep(setup: models.active, navigation: navigation, context: context)
                case .practice: practice
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.opacity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .spectrumWindowBackground()
        .focusEffectDisabled()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: navigation.step)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            SpectrumBars(mode: .breathing, barWidth: 15, spacing: 9, height: 84)
                .padding(.bottom, 30)
            Text("Dictate into any app")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.4)
                .padding(.bottom, 8)
            Text("Hold \(preferences.pushToTalkHotkey.displayName), speak, and let go. VibeScribe types what you said where your cursor is. Everything runs on this Mac.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(.bottom, 26)
            Button("Set up VibeScribe") {
                models.active.start()
                navigation.step = allGranted ? .model : .permissions
            }
            .buttonStyle(.spectrum(.primary, large: true))
            .keyboardShortcut(.defaultAction)
            Text("Downloads a \(downloadSize) speech model once. No account needed.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 18)
            Spacer()
            Spacer().frame(height: 30)
        }
        .padding(.horizontal, 36)
    }

    private var downloadSize: String {
        models.active.totalBytes.map(Format.bytes) ?? "630 MB"
    }

    // MARK: Permissions

    private var allGranted: Bool {
        permissions.microphone.isGranted && permissions.inputMonitoring.isGranted && permissions.accessibility.isGranted
    }

    private var permissionsStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                StepBar(current: .permissions)
                Text("Allow three things")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .padding(.bottom, 8)
                Text("macOS asks for each one separately. This list updates on its own when you come back from System Settings.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 380, alignment: .leading)
                    .padding(.bottom, 16)
                VStack(spacing: 8) {
                    PermissionCard(
                        systemImage: "mic",
                        title: "Microphone",
                        reason: "To hear you while the shortcut is held",
                        status: permissions.microphone,
                        isPrimary: !permissions.microphone.isGranted,
                        action: { permissions.requestMicrophone() }
                    )
                    PermissionCard(
                        systemImage: "keyboard",
                        title: "Input Monitoring",
                        reason: "To notice \(preferences.pushToTalkHotkey.displayName) in other apps",
                        status: permissions.inputMonitoring,
                        isPrimary: permissions.microphone.isGranted && !permissions.inputMonitoring.isGranted,
                        action: { permissions.requestInputMonitoring() }
                    )
                    PermissionCard(
                        systemImage: "doc.on.clipboard",
                        title: "Accessibility",
                        reason: "To paste the text for you. Without it, text is copied.",
                        status: permissions.accessibility,
                        isPrimary: permissions.microphone.isGranted && permissions.inputMonitoring.isGranted,
                        action: { permissions.requestAccessibility() }
                    )
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 8)
            Spacer(minLength: 0)
            OnboardingFooter {
                MiniDownload(setup: models.active)
                Spacer()
                if !allGranted {
                    Button("Skip for now") { navigation.step = .model }.buttonStyle(.spectrumGhost)
                }
                Button("Continue") { navigation.step = .model }
                    .buttonStyle(.spectrum(allGranted ? .primary : .normal, large: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Practice

    private var practice: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                StepBar(current: .practice)
                Text("Try it")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.bottom, 8)
                Text("Click in the box, hold \(preferences.pushToTalkHotkey.displayName), and say a sentence. Let go when you’re done.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 380, alignment: .leading)
                    .padding(.bottom, 20)
                PracticeField(text: $navigation.practiceText)
                if let result = navigation.practiceResult {
                    HStack(spacing: 6) {
                        Label("It works", systemImage: "checkmark")
                            .foregroundStyle(Theme.ok)
                            .font(.system(size: 12, weight: .medium))
                        Text("· \(Self.languageName(result.languageCode)) · \(String(format: "%.1f s", result.duration))")
                            .foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 12))
                    .padding(.top, 14)
                } else if !permissions.inputMonitoring.isGranted {
                    Text("The shortcut works in this window. Allow Input Monitoring to use it in other apps.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 8)
            Spacer(minLength: 0)
            OnboardingFooter {
                HStack(spacing: 5) {
                    Text("VibeScribe lives in the menu bar")
                    Image(systemName: "waveform")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
                Spacer()
                Button("Done") { navigation.onFinish() }
                    .buttonStyle(.spectrum(.primary, large: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func languageName(_ code: String?) -> String {
        guard let code, let name = Locale(identifier: "en").localizedString(forLanguageCode: code) else {
            return "Language detected"
        }
        return "\(name.capitalized) detected"
    }
}

private struct ModelStep: View {
    @ObservedObject var setup: WhisperModelSetup
    @ObservedObject var navigation: OnboardingNavigation
    let context: AppContext

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StepBar(current: .model)
                wave.padding(.top, 14).padding(.bottom, 26)
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.bottom, 22)
                content
            }
            .padding(.horizontal, 36)
            .padding(.top, 8)
            Spacer(minLength: 0)
            OnboardingFooter { footer }
        }
        .onAppear {
            // Reaching this step is consent to download. Only start from an idle state:
            // paused, failed and offline each have their own button or automatic resume.
            if !setup.isRunning, isIdle { setup.start() }
            advanceIfReady()
        }
        .onChange(of: setup.state) { advanceIfReady() }
    }

    private var isIdle: Bool {
        switch setup.state {
        case .checking, .notDownloaded: return true
        default: return false
        }
    }

    private func advanceIfReady() {
        guard setup.isReady else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if navigation.step == .model { navigation.step = .practice }
        }
    }

    @ViewBuilder
    private var wave: some View {
        switch setup.state {
        case .preparing, .ready:
            FillWave(progress: 1, breathing: setup.state == .preparing)
        case .checking:
            FillWave(progress: 0, breathing: true)
        case .paused, .interrupted, .failed:
            FillWave(progress: setup.progress ?? 0, paused: true)
        case .downloading, .notDownloaded:
            FillWave(progress: setup.progress ?? 0)
        }
    }

    private var title: String {
        switch setup.state {
        case .checking: return "Checking for the speech model"
        case .notDownloaded, .downloading: return "Downloading the speech model"
        case .paused: return "Download paused"
        case .interrupted: return "Download paused. You’re offline."
        case .preparing: return "Preparing the model for this Mac"
        case .ready: return "Speech model ready"
        case .failed: return "Speech model setup stopped"
        }
    }

    private var subtitle: String {
        switch setup.state {
        case .checking: return "Verifying files from an earlier download."
        case .notDownloaded, .downloading: return "You only do this once. After that, VibeScribe works without internet."
        case .paused(let completed, _):
            return "\(Format.bytes(completed)) is saved. Resume whenever you like."
        case .interrupted(let completed, _, _):
            return "\(Format.bytes(completed)) is saved. VibeScribe resumes on its own when your connection is back."
        case .preparing:
            return "The download is done. The first load optimises the model for your chip and takes about a minute. Later launches are faster."
        case .ready: return "Everything runs on this Mac."
        case .failed(let message): return message
        }
    }

    @ViewBuilder
    private var content: some View {
        switch setup.state {
        case .downloading(let completed, let total), .notDownloaded(let completed, let total):
            VStack(spacing: 8) {
                SpectrumMeter(progress: total > 0 ? Double(completed) / Double(total) : 0)
                HStack {
                    Text("\(Format.bytes(completed)) of \(Format.bytes(total)) · \(total > 0 ? Int(Double(completed) / Double(total) * 100) : 0)%")
                    Spacer()
                    Text(Format.timeRemaining(setup.secondsRemaining) ?? "")
                }
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondary)
            }
            .frame(width: 360)
        case .paused, .interrupted:
            HStack(spacing: 8) {
                Button("Resume now") { setup.start() }.buttonStyle(.spectrum(.primary, large: true))
                Button("Show details") { context.openSettings(.about) }.buttonStyle(.spectrum(.normal, large: true))
            }
        case .preparing, .checking:
            SpectrumMeter(progress: 1).opacity(0.5).frame(width: 360)
        case .failed:
            Button("Try again") { setup.start() }.buttonStyle(.spectrum(.primary, large: true))
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch setup.state {
        case .downloading:
            Text("You can close this window. The download continues from the menu bar.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Spacer()
            Button("Pause") { setup.pause() }.buttonStyle(.spectrum)
        case .interrupted(_, _, let reason):
            StatusDot(color: Theme.warn, size: 7)
            Text("Last attempt: \(reason)").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
            Spacer()
        case .preparing, .ready:
            Text("Download verified\(setup.totalBytes.map { " · \(Format.bytes($0))" } ?? "")")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Spacer()
        case .checking:
            Text("Checking each file’s fingerprint. This takes a few seconds.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Spacer()
        case .paused:
            Text("Your progress is saved.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Spacer()
        case .notDownloaded:
            Text("About \(setup.totalBytes.map(Format.bytes) ?? "630 MB"), downloaded once.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Spacer()
            Button("Download") { setup.start() }.buttonStyle(.spectrumPrimary)
        case .failed:
            Text("Files that passed verification are kept.").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            Spacer()
        }
    }
}

private struct StepBar: View {
    var current: OnboardingNavigation.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingNavigation.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(color(step))
                    .frame(height: 3)
            }
        }
        .padding(.bottom, 26)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingNavigation.Step.allCases.count)")
    }

    private func color(_ step: OnboardingNavigation.Step) -> Color {
        if step == current { return Theme.text }
        return step.rawValue < current.rawValue ? Theme.secondary : Color.white.opacity(0.1)
    }
}

private struct OnboardingFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 14) { content }
            .padding(.horizontal, 20)
            .frame(height: 58)
            .background(Theme.footer)
            .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }
}

private struct MiniDownload: View {
    @ObservedObject var setup: WhisperModelSetup

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: setup.isReady ? "checkmark" : "arrow.down.to.line")
                .font(.system(size: 11, weight: .semibold))
            Text("Speech model")
            if setup.isReady {
                Text("ready").foregroundStyle(Theme.ok)
            } else {
                SpectrumMeter(progress: setup.progress ?? 0).frame(width: 80)
                Text("\(Int((setup.progress ?? 0) * 100))%")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
        .fixedSize()
    }
}

private struct PracticeField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(height: 92)
            .fieldBackground(focused: focused)
            .onAppear { focused = true }
            .accessibilityLabel("Practice text")
    }
}
