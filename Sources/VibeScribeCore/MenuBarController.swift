import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let context: AppContext
    private let session: RecordingSession
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var animationTimer: Timer?

    var onQuit: () -> Void = { NSApp.terminate(nil) }

    init(context: AppContext, session: RecordingSession) {
        self.context = context
        self.session = session
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        statusItem.button?.setAccessibilityLabel("VibeScribe")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        Publishers.CombineLatest4(
            context.status.$phase,
            context.preferences.$language,
            context.preferences.$showLanguageInMenuBar,
            context.models.$activeState
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] phase, _, _, _ in
            self?.updateAnimation(for: phase)
            self?.refreshButton()
        }
        .store(in: &cancellables)
    }

    // MARK: Status item

    private func updateAnimation(for phase: AppPhase) {
        let animates = phase == .recording || phase == .transcribing
        if animates, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshButton() }
            }
        } else if !animates {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let phase = context.status.phase
        let preferences = context.preferences
        let code = preferences.showLanguageInMenuBar ? preferences.language.badge : nil
        var title = code
        button.appearsDisabled = false

        switch phase {
        case .recording:
            button.image = StatusIcons.bars(level: CGFloat(session.level.level), time: Date().timeIntervalSinceReferenceDate)
            let elapsed = session.startedAt.map { Date().timeIntervalSince($0) } ?? 0
            title = Format.duration(elapsed)
        case .transcribing:
            button.image = StatusIcons.thinking(time: Date().timeIntervalSinceReferenceDate)
        case .settingUp(let progress):
            button.image = StatusIcons.ring(progress: progress)
            title = progress.map { "\(Int($0 * 100))%" }
        case .shortcutPaused:
            button.image = StatusIcons.waveform
            button.appearsDisabled = true
        case .ready, .attention:
            button.image = StatusIcons.waveform
        }

        let text = NSMutableAttributedString()
        if let title {
            text.append(NSAttributedString(
                string: " " + title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]
            ))
        }
        if case .attention(let issue) = phase {
            let color: NSColor = if case .modelFailed = issue { .systemRed } else { .systemOrange }
            text.append(NSAttributedString(
                string: " ●",
                attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 7)]
            ))
        }
        button.attributedTitle = text
        button.toolTip = "VibeScribe — \(phase.title)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let phase = context.status.phase
        if case .settingUp = phase {
            buildSetupMenu()
        } else {
            buildMainMenu(phase: phase)
        }
    }

    private func buildSetupMenu() {
        let setup = context.models.active
        menu.addItem(hostingItem(MenuSetupHeader(setup: setup)))
        menu.addItem(.separator())
        switch setup.state {
        case .downloading:
            menu.addItem(item("Pause download") { setup.pause() })
        case .paused, .interrupted, .notDownloaded:
            menu.addItem(item("Resume download") { setup.start() })
        default:
            break
        }
        menu.addItem(item("Show setup window") { [weak self] in self?.context.openSetup() })
        menu.addItem(.separator())
        menu.addItem(item("Quit VibeScribe", key: "q") { [weak self] in self?.onQuit() })
    }

    private func buildMainMenu(phase: AppPhase) {
        let preferences = context.preferences
        menu.addItem(hostingItem(MenuStatusHeader(phase: phase, subtitle: subtitle(for: phase))))
        if case .attention(let issue) = phase {
            let fix = item(issue.fixTitle) { [weak self] in
                if let pane = issue.settingsPane {
                    SystemSettings.open(pane)
                } else {
                    self?.context.models.active.start()
                }
            }
            menu.addItem(fix)
        }
        if let last = context.history.last {
            menu.addItem(hostingItem(MenuLastTranscript(entry: last) { [weak self] in
                self?.context.output.copy(last.text)
                self?.menu.cancelTracking()
            }))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Language"))
        for (index, language) in preferences.pinnedLanguages.enumerated() {
            let entry = item(language.displayName, key: "\(index + 1)") {
                preferences.select(language)
            }
            entry.state = preferences.language == language ? .on : .off
            menu.addItem(entry)
        }
        if !preferences.pinnedLanguages.contains(preferences.language) {
            let current = item(preferences.language.displayName) {}
            current.state = .on
            menu.addItem(current)
        }
        menu.addItem(item("More languages…") { [weak self] in self?.context.openLanguagePicker(.choose) })

        menu.addItem(.separator())
        menu.addItem(item("History…", key: "y") { [weak self] in self?.context.openSettings(.history) })
        let pause = item("Pause shortcut") { preferences.isShortcutPaused.toggle() }
        pause.state = preferences.isShortcutPaused ? .on : .off
        menu.addItem(pause)
        menu.addItem(item("Settings…", key: ",") { [weak self] in self?.context.openSettings(.general) })
        if !preferences.hasCompletedOnboarding {
            menu.addItem(item("Finish setup…") { [weak self] in self?.context.openSetup() })
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit VibeScribe", key: "q") { [weak self] in self?.onQuit() })
    }

    private func subtitle(for phase: AppPhase) -> String {
        let key = context.preferences.pushToTalkHotkey.displayName
        switch phase {
        case .ready:
            switch context.preferences.triggerMode {
            case .holdOrTap: return "Hold \(key) to dictate · tap for hands-free"
            case .holdOnly: return "Hold \(key) to dictate"
            case .tapOnly: return "Tap \(key) to start and stop"
            }
        case .recording: return "Let go or tap \(key) to paste · esc cancels"
        case .transcribing: return "Turning your speech into text on this Mac"
        case .shortcutPaused: return "\(key) is ignored until you resume"
        case .attention(let issue): return issue.detail
        case .settingUp: return ""
        }
    }

    private func item(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
        return item
    }

    private func hostingItem<Content: View>(_ view: Content) -> NSMenuItem {
        let hosting = NSHostingView(rootView: view.frame(width: 290, alignment: .leading))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let item = NSMenuItem()
        item.view = hosting
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}

// MARK: Menu content

struct MenuStatusHeader: View {
    var phase: AppPhase
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                StatusDot(color: phase.color)
                Text(phase.title).font(.system(size: 13, weight: .semibold))
            }
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

struct MenuSetupHeader: View {
    @ObservedObject var setup: WhisperModelSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "arrow.down.to.line")
                .font(.system(size: 13, weight: .semibold))
            SpectrumMeter(progress: setup.progress ?? 0, track: Color.primary.opacity(0.1))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var title: String {
        switch setup.state {
        case .paused: return "Download paused"
        case .interrupted: return "Waiting for a connection"
        case .checking, .preparing: return "Preparing speech model"
        default: return "Downloading speech model"
        }
    }

    private var detail: String {
        switch setup.state {
        case .downloading(let completed, let total), .paused(let completed, let total),
             .notDownloaded(let completed, let total), .interrupted(let completed, let total, _):
            var text = "\(Format.bytes(completed)) of \(Format.bytes(total))"
            if let remaining = Format.timeRemaining(setup.secondsRemaining) { text += " · \(remaining)" }
            return text
        default:
            return "This takes about a minute."
        }
    }
}

struct MenuLastTranscript: View {
    var entry: HistoryEntry
    var copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last transcript · \(entry.date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", action: copy)
                    .controlSize(.small)
            }
            Text(entry.text)
                .font(.system(size: 12.5))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

// MARK: Icons

enum StatusIcons {
    static var waveform: NSImage {
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VibeScribe")
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }

    private static let profile: [CGFloat] = [0.34, 0.72, 0.48, 1.0, 0.56, 0.78, 0.34]
    private static let colors: [NSColor] = Theme.spectrum.map { NSColor($0) }

    /// Colour appears only while recording, so a live microphone is noticeable.
    static func bars(level: CGFloat, time: TimeInterval) -> NSImage {
        drawBars(template: false) { index in
            let wobble = 0.72 + 0.28 * sin(time * (7 + Double(index)) + Double(index) * 1.3)
            return min(max(0.22 + 0.78 * level * profile[index] * CGFloat(wobble), 0.2), 1)
        }
    }

    static func thinking(time: TimeInterval) -> NSImage {
        drawBars(template: true) { index in
            0.25 + 0.55 * CGFloat(max(0, sin(time * 4.4 - Double(index) * 0.55)))
        }
    }

    static func ring(progress: Double?) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2.5
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            let fraction = progress ?? 0.25
            arc.appendArc(
                withCenter: NSPoint(x: rect.midX, y: rect.midY),
                radius: inset.width / 2,
                startAngle: 90,
                endAngle: 90 - 360 * CGFloat(max(fraction, 0.03)),
                clockwise: true
            )
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawBars(template: Bool, height fraction: @escaping (Int) -> CGFloat) -> NSImage {
        let barWidth: CGFloat = 2.2
        let gap: CGFloat = 1.6
        let size = NSSize(width: 7 * barWidth + 6 * gap, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            for index in 0..<7 {
                let height = max(barWidth, rect.height * fraction(index))
                let bar = NSRect(
                    x: CGFloat(index) * (barWidth + gap),
                    y: (rect.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                (template ? NSColor.black : colors[index]).setFill()
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}
