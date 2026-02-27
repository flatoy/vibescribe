import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            homeTab
                .tabItem { Text("Home") }
            logsTab
                .tabItem { Text("Logs") }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var homeTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            permissionsSection
            Divider()
            settingsSection
            transcriptSection
            Spacer()
        }
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logs")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    appState.clearLogs()
                }
            }

            if appState.logs.isEmpty {
                Text("No logs yet.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.logs) { entry in
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
            Text("Push-to-talk transcription powered by Deepgram")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)
            PermissionRow(
                title: "Recording",
                status: appState.microphonePermission,
                actionTitle: "Request"
            ) {
                appState.requestMicrophonePermission()
            }
            PermissionRow(
                title: "Pasting",
                status: appState.accessibilityPermission,
                actionTitle: "Request"
            ) {
                appState.requestAccessibilityPermission()
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Push-to-Talk") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hotkey")
                        .font(.subheadline)
                    Text(appState.hotkey.displayName)
                        .foregroundStyle(.secondary)
                    Text("Change this in code for now (Hotkey.pushToTalkDefault).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Deepgram") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("API Key", text: $appState.apiKey)
                    Picker("Language", selection: $appState.deepgramLanguage) {
                        ForEach(DeepgramLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    Text("Automatic uses Deepgram multilingual mode (language=multi).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transcriptSection: some View {
        GroupBox("Latest Transcript") {
            ScrollView {
                Text(transcriptText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }

    private var transcriptText: String {
        if !appState.displayTranscript.isEmpty {
            return appState.displayTranscript
        }
        return "Waiting for transcription..."
    }

    private func copyLogEntry(_ entry: LogEntry) {
        let text = "\(Self.formatter.string(from: entry.timestamp)) \(entry.level.rawValue) \(entry.message)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
