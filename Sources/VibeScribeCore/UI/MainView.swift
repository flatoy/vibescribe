import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var recordingSession: RecordingSession
    @ObservedObject var transcript: TranscriptBuffer
    @ObservedObject var permissions: Permissions
    @ObservedObject var preferences: Preferences
    @ObservedObject var logger: Logger
    @ObservedObject var modelSetup: WhisperModelSetup

    var body: some View {
        TabView {
            Group {
                if modelSetup.isReady {
                    homeTab
                } else {
                    setupTab
                }
            }
            .tabItem { Text("Home") }
            logsTab
                .tabItem { Text("Logs") }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 560)
    }

    private var setupTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            Spacer()
            GroupBox("Speech model") {
                VStack(alignment: .leading, spacing: 16) {
                    switch modelSetup.state {
                    case .checking:
                        Text("Checking for a downloaded speech model…")
                            .font(.headline)
                        ProgressView()
                    case .downloading(let completed, let total):
                        Text("Downloading for offline transcription")
                            .font(.headline)
                        Text("This one-time download is about 630 MB. After setup, transcription works without internet.")
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(completed), total: Double(max(total, 1)))
                            .accessibilityLabel("Speech model download")
                        HStack {
                            Text("\(Int(Double(completed) / Double(max(total, 1)) * 100))%")
                            Spacer()
                            Text("\(Self.bytes(completed)) of \(Self.bytes(total))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    case .preparing:
                        Text("Preparing the speech model…")
                            .font(.headline)
                        Text("Loading the model can take about a minute. Your download is complete.")
                            .foregroundStyle(.secondary)
                        ProgressView()
                    case .ready:
                        EmptyView()
                    case .failed(let message):
                        Text("Speech model setup stopped")
                            .font(.headline)
                        Text(message)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            modelSetup.start()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            Spacer()
        }
    }

    private var homeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                permissionsSection
                Divider()
                settingsSection
                transcriptSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)
        }
        .onAppear {
            permissions.refresh()
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    logger.clear()
                }
            }

            if logger.entries.isEmpty {
                Text("No logs yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(logger.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(Self.formatter.string(from: entry.timestamp)) \(entry.level.rawValue)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button {
                                        copyLogEntry(entry)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .help("Copy log entry")
                                }
                                Text(entry.message)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VibeScribe")
                .font(.system(size: 28, weight: .semibold))
            Text("Private transcription powered by WhisperKit")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)
            PermissionRow(
                title: "Recording",
                status: permissions.microphone,
                actionTitle: "Request"
            ) {
                permissions.requestMicrophone()
            }
            PermissionRow(
                title: "Pasting",
                status: permissions.accessibility,
                actionTitle: "Request"
            ) {
                permissions.requestAccessibility()
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Push-to-Talk") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hotkey")
                        .font(.subheadline)
                    Text(Hotkey.pushToTalkDefault.displayName)
                        .foregroundStyle(.secondary)
                    Text("Change this in code for now (Hotkey.pushToTalkDefault).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Transcription") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Language", selection: $preferences.language) {
                        ForEach(WhisperLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    Text("The downloaded model supports 100 languages. Accuracy varies by language and recording. Automatic detects the language on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transcriptSection: some View {
        GroupBox("Latest Transcript") {
            VStack(alignment: .leading, spacing: 8) {
                Text(recordingSession.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(transcriptText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 100)
            }
        }
    }

    private var transcriptText: String {
        if !transcript.final.isEmpty {
            return transcript.final
        }
        if !transcript.last.isEmpty {
            return transcript.last
        }
        switch recordingSession.state {
        case .recording:
            return "Listening..."
        case .finalizing:
            return "Transcribing..."
        case .idle:
            return "No transcript yet."
        }
    }

    private func copyLogEntry(_ entry: LogEntry) {
        let text = "\(Self.formatter.string(from: entry.timestamp)) \(entry.level.rawValue) \(entry.message)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle) {
                action()
            }
        }
    }
}

private extension MainView {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
