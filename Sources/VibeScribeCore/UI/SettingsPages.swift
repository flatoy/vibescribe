import AppKit
import SwiftUI

// MARK: General

struct GeneralPage: View {
    let context: AppContext
    @ObservedObject private var preferences: Preferences
    @ObservedObject private var status: AppStatus
    @ObservedObject private var microphones: MicrophoneMonitor
    @ObservedObject private var level: LevelMeter
    @ObservedObject private var loginItem: LoginItem

    init(context: AppContext) {
        self.context = context
        preferences = context.preferences
        status = context.status
        microphones = context.microphones
        level = context.microphones.level
        loginItem = context.loginItem
    }

    var body: some View {
        SettingsPageBody {
            if let issue = permissionIssue {
                WarningBanner(title: Self.bannerTitle(issue), detail: Self.bannerDetail(issue)) {
                    Button("Open System Settings") {
                        if let pane = issue.settingsPane { SystemSettings.open(pane) }
                    }
                    .buttonStyle(.spectrum)
                }
            }

            GroupLabel(title: "Recording")
            SettingsGroup {
                SettingsRow(title: "Microphone") {
                    LevelSegments(level: level.level)
                    Picker("Microphone", selection: $preferences.microphoneUID) {
                        Text("System default (\(microphones.defaultDevice?.name ?? "none"))").tag(String?.none)
                        ForEach(microphones.devices) { device in
                            Text(device.name).tag(String?.some(device.uid))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                RowDivider()
                SettingsRow(title: "Play sounds", detail: "A soft click when recording starts and stops") {
                    SpectrumToggle(isOn: $preferences.playSounds, label: "Play sounds")
                }
            }

            GroupLabel(title: "When text is ready")
            SettingsGroup {
                SettingsRow(title: "Send text to") {
                    SpectrumSegmented(
                        options: OutputMode.allCases.map { ($0, $0.title) },
                        selection: $preferences.outputMode
                    )
                }
                RowDivider()
                SettingsRow(title: "Restore clipboard after pasting", detail: "Puts back whatever you had copied before") {
                    SpectrumToggle(isOn: $preferences.restoreClipboard, label: "Restore clipboard")
                }
                .disabled(preferences.outputMode == .clipboard)
                .opacity(preferences.outputMode == .clipboard ? 0.5 : 1)
            }

            SettingsGroup {
                SettingsRow(
                    title: "Open at login",
                    detail: loginItem.isAvailable ? nil : "Available in the packaged app, not with swift run"
                ) {
                    SpectrumToggle(
                        isOn: Binding(
                            get: { loginItem.isEnabled },
                            set: { loginItem.setEnabled($0, logger: context.logger) }
                        ),
                        label: "Open at login"
                    )
                    .disabled(!loginItem.isAvailable)
                }
                RowDivider()
                SettingsRow(title: "Show language in menu bar") {
                    SpectrumToggle(isOn: $preferences.showLanguageInMenuBar, label: "Show language in menu bar")
                }
            }
        }
        .onAppear {
            microphones.refresh()
            microphones.startMetering(uid: preferences.microphoneUID)
            loginItem.refresh()
        }
        .onDisappear { microphones.stopMetering() }
        .onChange(of: preferences.microphoneUID) { _, uid in microphones.startMetering(uid: uid) }
    }

    private var permissionIssue: AppIssue? {
        status.issues.first { issue in
            if case .modelFailed = issue { return false }
            return true
        }
    }

    static func bannerTitle(_ issue: AppIssue) -> String {
        switch issue {
        case .pastingOff: return "VibeScribe can’t paste right now"
        case .microphoneOff: return "VibeScribe can’t hear you"
        case .shortcutBlocked: return "The shortcut only works inside VibeScribe"
        case .modelFailed: return issue.title
        }
    }

    static func bannerDetail(_ issue: AppIssue) -> String {
        switch issue {
        case .pastingOff: return "Accessibility permission is off. Transcripts are copied, and you press ⌘V yourself."
        case .microphoneOff: return "Microphone access is off. Allow it in System Settings to dictate."
        case .shortcutBlocked: return "Input Monitoring is off, so the shortcut isn’t noticed in other apps."
        case .modelFailed(let message): return message
        }
    }
}

/// A small switch in the accent colour, drawn the same in active and inactive windows.
struct SpectrumToggle: View {
    @Binding var isOn: Bool
    var label: String

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.accent : Color(hex: 0x48484E))
                Circle()
                    .fill(Color(hex: 0xF1F1F3))
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 32, height: 19)
            .focusRing(cornerRadius: 9.5)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: Shortcut

struct ShortcutPage: View {
    let context: AppContext
    @ObservedObject private var preferences: Preferences

    init(context: AppContext) {
        self.context = context
        preferences = context.preferences
    }

    var body: some View {
        SettingsPageBody {
            GroupLabel(title: "Dictation")
            SettingsGroup {
                SettingsRow(
                    title: "Dictation key",
                    detail: "Press the key you want to use. Single modifier keys like Right ⌥ work best."
                ) {
                    ShortcutField(
                        recorder: context.recorder,
                        target: .pushToTalk,
                        hotkey: preferences.pushToTalkHotkey,
                        isDefault: preferences.pushToTalkHotkey == .pushToTalkDefault,
                        reset: { preferences.pushToTalkHotkey = .pushToTalkDefault }
                    )
                }
                RowDivider()
                SettingsRow(title: "How it works") {
                    SpectrumSegmented(
                        options: TriggerMode.allCases.map { ($0, $0.title) },
                        selection: $preferences.triggerMode
                    )
                }
                RowDivider()
                explanation
                RowDivider()
                SettingsRow(title: "Cancel recording", detail: "Throw away the audio without pasting") {
                    Keycap(label: "esc")
                }
            }

            GroupLabel(title: "Languages")
            SettingsGroup {
                SettingsRow(title: "Open language picker") {
                    ShortcutField(
                        recorder: context.recorder,
                        target: .languagePicker,
                        hotkey: preferences.languagePickerHotkey,
                        isDefault: preferences.languagePickerHotkey == .languagePickerDefault,
                        reset: { preferences.languagePickerHotkey = .languagePickerDefault }
                    )
                }
                RowDivider()
                SettingsRow(title: "Switch to pinned language", detail: "Works while the picker is open, or from the menu") {
                    HStack(spacing: 6) {
                        Keycap(label: "⌘1")
                        Text("–").foregroundStyle(Theme.tertiary)
                        Keycap(label: "⌘3")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .fieldBackground()
                }
            }
        }
    }

    private var explanation: some View {
        let key = preferences.pushToTalkHotkey.displayName
        let text: AttributedString = {
            switch preferences.triggerMode {
            case .holdOrTap:
                return (try? AttributedString(markdown: "**Hold** \(key) to talk, and let go to paste.  \n**Tap** it to start hands-free, and tap again to stop.")) ?? ""
            case .holdOnly:
                return (try? AttributedString(markdown: "**Hold** \(key) to talk, and let go to paste. Short taps are ignored.")) ?? ""
            case .tapOnly:
                return (try? AttributedString(markdown: "**Tap** \(key) to start, and tap again to stop and paste.")) ?? ""
            }
        }()
        return Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}

struct ShortcutField: View {
    @ObservedObject var recorder: HotkeyRecorder
    var target: HotkeyRecorder.Target
    var hotkey: Hotkey
    var isDefault: Bool
    var reset: () -> Void

    private var isRecording: Bool { recorder.target == target }

    var body: some View {
        HStack(spacing: 6) {
            if !isDefault, !isRecording {
                Button("Reset", action: reset).buttonStyle(.spectrumGhost)
            }
            Button {
                isRecording ? recorder.stop() : recorder.start(target)
            } label: {
                HStack(spacing: 6) {
                    if isRecording {
                        Text("Press a key…").foregroundStyle(Theme.secondary)
                        Spacer(minLength: 16)
                        Text("esc").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    } else {
                        KeycapRow(labels: hotkey.keycaps)
                    }
                }
                .padding(.horizontal, 10)
                .frame(minWidth: isRecording ? 170 : nil, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording ? Theme.accent.opacity(0.08) : Theme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isRecording ? Theme.accent : Theme.hairlineStrong,
                            style: StrokeStyle(lineWidth: isRecording ? 1.5 : 1, dash: isRecording ? [4, 3] : [])
                        )
                )
                .focusRing(cornerRadius: 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click, then press the new shortcut")
            .accessibilityLabel(isRecording ? "Recording shortcut. Press a key." : "Shortcut \(hotkey.displayName). Click to change.")
        }
    }
}

// MARK: Language

struct LanguagePage: View {
    let context: AppContext
    @ObservedObject private var preferences: Preferences
    @FocusState private var vocabularyFocused: Bool

    init(context: AppContext) {
        self.context = context
        preferences = context.preferences
    }

    var body: some View {
        SettingsPageBody {
            SettingsGroup {
                SettingsRow(
                    title: "Speaking",
                    detail: "Automatic works for most people. Pick a language if short phrases come out in the wrong one."
                ) {
                    Button {
                        context.openLanguagePicker(.choose)
                    } label: {
                        HStack(spacing: 8) {
                            Text(preferences.language.displayName)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .buttonStyle(.spectrum)
                }
            }

            GroupLabel(title: "Pinned")
            SettingsGroup {
                FlowChips(
                    pinned: preferences.pinnedLanguages,
                    canAdd: preferences.pinnedLanguages.count < Preferences.maxPinnedLanguages,
                    remove: { preferences.togglePin($0) },
                    add: { context.openLanguagePicker(.pin) }
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupLabel(title: "Vocabulary")
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Words to spell your way").font(.system(size: 13, weight: .medium))
                        Text("Names, products and jargon, separated by commas. These are hints to the model, not guarantees.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                    }
                    TextEditor(text: $preferences.vocabulary)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($vocabularyFocused)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .frame(height: 64)
                        .fieldBackground(focused: vocabularyFocused)
                        .accessibilityLabel("Vocabulary")
                    HStack {
                        let count = preferences.vocabularyWords.count
                        Text(count == 1 ? "1 word" : "\(count) words")
                        Spacer()
                        Text("Long lists can reduce accuracy")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct FlowChips: View {
    var pinned: [WhisperLanguage]
    var canAdd: Bool
    var remove: (WhisperLanguage) -> Void
    var add: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(pinned.enumerated()), id: \.element) { index, language in
                HStack(spacing: 6) {
                    Keycap(label: "⌘\(index + 1)", compact: true)
                    Text(language.displayName).font(.system(size: 12))
                    Button {
                        remove(language)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unpin \(language.displayName)")
                }
                .padding(.leading, 5)
                .padding(.trailing, 8)
                .frame(height: 24)
                .background(Capsule().fill(Theme.iconWell))
            }
            if canAdd {
                Button(action: add) {
                    Text("+ Pin a language")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .overlay(Capsule().strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: History

struct HistoryPage: View {
    let context: AppContext
    @ObservedObject private var history: TranscriptHistory
    @ObservedObject private var preferences: Preferences
    @State private var query = ""
    @State private var hovered: HistoryEntry.ID?
    @State private var confirmClear = false

    init(context: AppContext) {
        self.context = context
        history = context.history
        preferences = context.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    TextField("Search transcripts", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .fieldBackground()
                Picker("Retention", selection: $preferences.historyRetention) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 24)

            if history.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .padding(.top, 4)
        .confirmationDialog("Clear all history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("Transcripts are removed from this Mac. This can’t be undone.")
        }
    }

    private var list: some View {
        let results = history.search(query)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(groups(results).enumerated()), id: \.offset) { index, group in
                    Text(group.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.top, index == 0 ? 4 : 10)
                        .padding(.bottom, 6)
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { offset, entry in
                        HistoryRow(
                            entry: entry,
                            isHovered: hovered == entry.id,
                            showsDivider: offset > 0 && hovered != entry.id && hovered != group.entries[offset - 1].id,
                            copy: { context.output.copy(entry.text) },
                            pasteAgain: { context.pasteAgain(entry) }
                        )
                        .onHover { hovering in
                            if hovering { hovered = entry.id } else if hovered == entry.id { hovered = nil }
                        }
                    }
                }
                if results.isEmpty {
                    Text("No transcripts match “\(query.trimmed)”.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                }
                HStack {
                    Spacer()
                    Button("Clear History…") { confirmClear = true }.buttonStyle(.spectrumGhost)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            SpectrumBars(mode: .still, barWidth: 4, spacing: 3, height: 22).opacity(0.5)
            Text(preferences.historyRetention == .off ? "History is off" : "Nothing dictated yet")
                .font(.system(size: 14, weight: .semibold))
            Group {
                if preferences.historyRetention == .off {
                    Text("Transcripts aren’t kept. Choose how long to keep them to see them here.")
                } else {
                    Text("Hold \(preferences.pushToTalkHotkey.displayName) in any app and speak. Your transcripts appear here, stored only on this Mac.")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private func groups(_ entries: [HistoryEntry]) -> [(title: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var result: [(title: String, entries: [HistoryEntry])] = []
        for entry in entries {
            let title: String
            if calendar.isDateInToday(entry.date) {
                title = "Today"
            } else if calendar.isDateInYesterday(entry.date) {
                title = "Yesterday"
            } else {
                title = formatter.string(from: entry.date)
            }
            if result.last?.title == title {
                result[result.count - 1].entries.append(entry)
            } else {
                result.append((title, [entry]))
            }
        }
        return result
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isHovered: Bool
    let showsDivider: Bool
    let copy: () -> Void
    let pasteAgain: () -> Void

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.time.string(from: entry.date))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .frame(width: 48, alignment: .leading)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text((entry.languageCode ?? "auto").uppercased())
                    Text(Format.duration(entry.duration))
                    if let app = entry.appName { Text("→ \(app)") }
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Button("Copy", action: copy)
                Button("Paste again", action: pasteAgain)
            }
            .buttonStyle(.spectrum)
            .controlSize(.small)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Color.white.opacity(0.05) : .clear))
        .overlay(alignment: .top) { if showsDivider { Theme.hairline.frame(height: 1) } }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Speech model

struct ModelPage: View {
    let context: AppContext
    @ObservedObject private var models: SpeechModelLibrary
    @State private var confirmSwitch: SpeechModelID?
    @State private var confirmDelete: SpeechModelID?

    init(context: AppContext) {
        self.context = context
        models = context.models
    }

    var body: some View {
        let active = models.active
        SettingsPageBody {
            SettingsGroup {
                HStack(spacing: 16) {
                    modelIcon(failed: isFailed(active.state))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(active.modelID.name).font(.system(size: 14, weight: .semibold))
                            Tag(title: "In use")
                        }
                        Text("\(active.modelID.summary) · \(active.totalBytes.map(Format.bytes) ?? "")")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                RowDivider()
                ActiveModelStatus(setup: active)
                RowDivider()
                SettingsRow(title: "Stored in Application Support") {
                    Button("Show in Finder") {
                        let folder = active.modelFolder
                        if FileManager.default.fileExists(atPath: folder.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        } else {
                            NSWorkspace.shared.open(folder.deletingLastPathComponent())
                        }
                    }
                    .buttonStyle(.spectrumGhost)
                }
            }

            GroupLabel(title: "Other models")
            SettingsGroup {
                let others = SpeechModelID.allCases.filter { $0 != models.activeID }
                ForEach(Array(others.enumerated()), id: \.element) { index, id in
                    if index > 0 { RowDivider() }
                    OtherModelRow(
                        setup: models.setup(for: id),
                        activeName: models.activeID.shortName,
                        onSwitch: { confirmSwitch = id },
                        onDelete: { confirmDelete = id }
                    )
                }
            }
        }
        .alert(
            "Switch to \(confirmSwitch?.shortName ?? "")?",
            isPresented: Binding(get: { confirmSwitch != nil }, set: { if !$0 { confirmSwitch = nil } }),
            presenting: confirmSwitch
        ) { id in
            Button("Switch") { models.switchTo(id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Dictation pauses for about a minute while the model loads for this Mac.")
        }
        .alert(
            "Delete \(confirmDelete?.shortName ?? "")?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { id in
            Button("Delete", role: .destructive) {
                do { try models.setup(for: id).delete() } catch {
                    context.logger.append("Could not delete the model: \(error.localizedDescription)", level: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This frees about 630 MB. You can download it again later.")
        }
    }

    private func isFailed(_ state: WhisperModelSetup.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func modelIcon(failed: Bool) -> some View {
        Group {
            if failed {
                FillWave(progress: 2.0 / 7.0, paused: true, barWidth: 4, spacing: 3, height: 30)
            } else {
                SpectrumBars(mode: .still, barWidth: 4, spacing: 3, height: 22)
            }
        }
        .frame(width: 52, height: 52)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct ActiveModelStatus: View {
    @ObservedObject var setup: WhisperModelSetup

    var body: some View {
        switch setup.state {
        case .ready:
            SettingsRow(title: "Works offline", detail: "Speech never leaves this Mac") {
                Label("Ready", systemImage: "checkmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ok)
            }
        case .checking:
            SettingsRow(title: "Checking the downloaded files…") { ProgressRing(progress: nil, color: Theme.accent) }
        case .preparing:
            SettingsRow(title: "Preparing the model for this Mac", detail: "The first load takes about a minute.") {
                ProgressRing(progress: nil, color: Theme.accent)
            }
        case .downloading(let completed, let total), .paused(let completed, let total),
             .notDownloaded(let completed, let total), .interrupted(let completed, let total, _):
            DownloadProgressRow(setup: setup, completed: completed, total: total, pauseTitle: "Pause")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if message.contains("disk space") {
                        Button("Open Storage Settings") { SystemSettings.open(.storage) }.buttonStyle(.spectrum)
                    }
                    Spacer()
                    Button("Try again") { setup.start() }.buttonStyle(.spectrumPrimary)
                }
            }
            .padding(14)
        }
    }
}

private struct DownloadProgressRow: View {
    @ObservedObject var setup: WhisperModelSetup
    let completed: Int64
    let total: Int64
    let pauseTitle: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                switch setup.state {
                case .downloading:
                    Button(pauseTitle) { pauseTitle == "Cancel" ? setup.cancel() : setup.pause() }.buttonStyle(.spectrum)
                default:
                    Button(completed > 0 ? "Resume" : "Download") { setup.start() }.buttonStyle(.spectrum)
                }
            }
            SpectrumMeter(progress: total > 0 ? Double(completed) / Double(total) : 0)
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14)
    }

    private var title: String {
        switch setup.state {
        case .downloading: return "Downloading"
        case .paused: return "Download paused"
        case .interrupted: return "Waiting for a connection"
        default: return "Not downloaded"
        }
    }

    private var detail: String {
        var parts = ["\(Format.bytes(completed)) of \(Format.bytes(total))"]
        if let remaining = Format.timeRemaining(setup.secondsRemaining) { parts.append(remaining) }
        if case .interrupted(_, _, let reason) = setup.state { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}

private struct OtherModelRow: View {
    @ObservedObject var setup: WhisperModelSetup
    let activeName: String
    let onSwitch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(setup.modelID.name).font(.system(size: 13, weight: .medium))
                        Tag(title: setup.modelID.badge, color: Theme.accent)
                    }
                    Text("\(setup.modelID.summary) · \(setup.totalBytes.map(Format.bytes) ?? "")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            switch setup.state {
            case .downloading(let completed, let total), .paused(let completed, let total),
                 .interrupted(let completed, let total, _):
                DownloadProgressRow(
                    setup: setup,
                    completed: completed,
                    total: total,
                    pauseTitle: "Cancel",
                    note: "Dictation keeps using \(activeName) until this finishes. You’ll be asked before switching."
                )
                .padding(.top, -12)
            case .failed(let message):
                Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.bad)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch setup.state {
        case .ready:
            Button("Delete…", action: onDelete).buttonStyle(.spectrum(.danger))
            Button("Use this model", action: onSwitch).buttonStyle(.spectrumPrimary)
        case .notDownloaded(let completed, _):
            Button(completed > 0 ? "Resume" : "Download") { setup.start() }.buttonStyle(.spectrum)
        case .failed:
            Button("Try again") { setup.start() }.buttonStyle(.spectrum)
        case .checking, .preparing:
            ProgressRing(progress: nil, color: Theme.accent)
        case .downloading, .paused, .interrupted:
            EmptyView()
        }
    }
}

// MARK: About & diagnostics

struct AboutPage: View {
    let context: AppContext
    @ObservedObject private var permissions: Permissions
    @ObservedObject private var logger: Logger
    @State private var copied = false

    init(context: AppContext) {
        self.context = context
        permissions = context.permissions
        logger = context.logger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VibeScribe \(AppInfo.version)").font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 4) {
                        Text("Local transcription with WhisperKit ·")
                        Button("Licences") { NSWorkspace.shared.open(AppInfo.licensesFolder) }
                            .buttonStyle(.plain)
                            .underline()
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                }
            }

            SettingsGroup {
                SettingsRow(title: "Permissions") {
                    HStack(spacing: 12) {
                        permission("Microphone", permissions.microphone, .microphone)
                        permission("Input Monitoring", permissions.inputMonitoring, .inputMonitoring)
                        permission("Accessibility", permissions.accessibility, .accessibility)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Log").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { logger.clear() }.buttonStyle(.spectrumGhost)
                Button(copied ? "Copied" : "Copy diagnostic report") {
                    context.output.copy(context.diagnosticReport())
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(.spectrum)
            }

            LogView(entries: logger.entries)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private func permission(_ title: String, _ status: PermissionStatus, _ pane: SystemSettings.Pane) -> some View {
        Button {
            guard !status.isGranted else { return }
            switch pane {
            case .microphone: permissions.requestMicrophone()
            case .inputMonitoring: permissions.requestInputMonitoring()
            case .accessibility: permissions.requestAccessibility()
            case .storage: SystemSettings.open(pane)
            }
        } label: {
            HStack(spacing: 5) {
                StatusDot(color: status.isGranted ? Theme.ok : Theme.warn, size: 7)
                Text(title).lineLimit(1).fixedSize()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(status.isGranted ? Theme.ok : Theme.warn)
        }
        .buttonStyle(.plain)
        .help(status.isGranted ? "\(title) is allowed" : "Open System Settings to allow \(title)")
    }
}

struct LogView: View {
    var entries: [LogEntry]

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty {
                        Text("No log entries yet.").foregroundStyle(Theme.tertiary)
                    }
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Self.time.string(from: entry.timestamp)).foregroundStyle(Theme.tertiary)
                            Text(entry.message).foregroundStyle(color(entry.level)).textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            .onAppear { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
            .onChange(of: entries.count) { proxy.scrollTo(entries.last?.id, anchor: .bottom) }
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .info: return Theme.secondary
        case .warning: return Theme.warn
        case .error: return Theme.bad
        }
    }
}
