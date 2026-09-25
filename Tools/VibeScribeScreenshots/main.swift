// Renders the app's real SwiftUI views with sample data, for the README.
// Usage: swift run VibeScribeScreenshots [output-folder]   (default: assets)

import AppKit
import SwiftUI
@testable import VibeScribeCore

// MARK: Rendering

@MainActor
func render<V: View>(_ view: V, size: CGSize, to url: URL, scale: CGFloat = 2) {
    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: .darkAqua)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let data = url.pathExtension == "jpg"
        ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])!
        : rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
    window.orderOut(nil)
    print("wrote \(url.path)")
}

// MARK: Pieces of desktop

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: 0xFF5F57))
            Circle().fill(Color(hex: 0xFEBC2E))
            Circle().fill(Color(hex: 0x28C840))
        }
        .frame(width: 52, height: 12)
    }
}

/// A window frame around a view, as macOS would draw it.
struct WindowFrame<Content: View>: View {
    var size: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) { TrafficLights().padding(.leading, 20).padding(.top, 14) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: Color(hex: 0x28144A).opacity(0.45), radius: 30, y: 24)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
    }
}

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3D3A5C), Color(hex: 0x2A2638)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: 0x5B6FA8), .clear], center: UnitPoint(x: 0.15, y: 0), startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(hex: 0xB0719B).opacity(0.9), .clear], center: UnitPoint(x: 0.9, y: 0.1), startRadius: 0, endRadius: 650)
        }
    }
}

struct FauxMenuBar<Item: View>: View {
    var compact = false
    @ViewBuilder var item: Item

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "apple.logo").font(.system(size: 13))
            Text("Notes").font(.system(size: 12.5, weight: .bold))
            ForEach(compact ? ["File", "Edit"] : ["File", "Edit", "Format", "View", "Window"], id: \.self) { Text($0) }
            Spacer()
            item
            if !compact {
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
            }
            Text(compact ? "14:02" : "Thu 14:02")
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Color(hex: 0x14121E).opacity(0.35))
    }
}

struct StatusItemGlyph: View {
    var recording: Bool
    var level: Float = 0.7
    var title: String

    var body: some View {
        HStack(spacing: 5) {
            if recording {
                SpectrumBars(mode: .live(level), barWidth: 2.2, spacing: 1.6, height: 14)
            } else {
                Image(systemName: "waveform")
            }
            Text(title).font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(recording ? 0.2 : 0)))
    }
}

/// SwiftUI stand-in for the status item menu, built from the same header and card views.
struct MenuReplica: View {
    var entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuStatusHeader(phase: .ready, subtitle: "Hold Right ⌥ to dictate · tap for hands-free")
            MenuLastTranscript(entry: entry) {}
            divider
            Text("Language").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 3)
            row("Automatic", key: "⌘1", checked: true)
            row("Norwegian", key: "⌘2", highlighted: true)
            row("English", key: "⌘3")
            row("More languages…")
            divider
            row("History…", key: "⌘Y")
            row("Pause shortcut")
            row("Settings…", key: "⌘,")
            divider
            row("Quit VibeScribe", key: "⌘Q")
        }
        .padding(.vertical, 5)
        .frame(width: 290)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x24222C).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 5)
    }

    private func row(_ title: String, key: String? = nil, checked: Bool = false, highlighted: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(checked ? 1 : 0).frame(width: 12)
            Text(title).font(.system(size: 13))
            Spacer()
            if let key { Text(key).font(.system(size: 12)).foregroundStyle(.white.opacity(highlighted ? 0.8 : 0.45)) }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Theme.accent : .clear))
        .padding(.horizontal, 5)
    }
}

// MARK: Sample app state

@MainActor
struct Sample {
    let context: AppContext
    let preferences: Preferences
    let models: SpeechModelLibrary
    let history: TranscriptHistory

    init() {
        let defaults = UserDefaults(suiteName: "VibeScribeScreenshots.\(UUID().uuidString)")!
        preferences = Preferences(defaults: defaults)
        preferences.pinnedLanguages = [.automatic, WhisperLanguage(rawValue: "no")!, .english]
        preferences.select(WhisperLanguage(rawValue: "sv")!)
        preferences.select(.automatic)
        preferences.vocabulary = "VibeScribe, WhisperKit, Schibsted, Flåtøy, Kubernetes, SwiftUI"
        let logger = Logger()
        for (message, level) in [
            ("Recording started (Right ⌥ hold)", LogLevel.info),
            ("Recording stopped · 6.2 s", .info),
            ("Transcribed 18 words · no", .info),
            ("Pasted into the active app.", .info),
            ("Language set to Automatic.", .info),
            ("Cached speech model large-v3 verified.", .info),
        ] { logger.append(message, level: level) }
        let permissions = Permissions()
        permissions.simulate(microphone: .authorized, inputMonitoring: .authorized, accessibility: .authorized)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("VibeScribeScreenshots")
        let client = WhisperKitClient(modelFolder: temp) { _, _ in }
        models = SpeechModelLibrary(
            preferences: preferences,
            logger: logger,
            client: client,
            folder: { temp.appendingPathComponent($0.rawValue) }
        )
        models.setup(for: .largeV3).simulate(.ready)
        models.setup(for: .largeV3Turbo).simulate(.notDownloaded(0, 648_432_373))
        history = TranscriptHistory(fileURL: nil)
        let now = Date()
        func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        history.simulate([
            HistoryEntry(date: now.addingTimeInterval(-120), text: "Kan du sende meg utkastet til presentasjonen før lunsj i morgen? Da rekker jeg å se på det.", languageCode: "no", duration: 6, appName: "Slack"),
            HistoryEntry(date: at(11, 42), text: "Refactor the recording session so the overlay observes a single state enum instead of three booleans, then update the tests.", languageCode: "en", duration: 9, appName: "Terminal"),
            HistoryEntry(date: at(9, 15), text: "Reminder to self: check whether the turbo model is fast enough for long dictation on the M1 Air.", languageCode: "en", duration: 5, appName: "Notes"),
            HistoryEntry(date: at(17, 48, daysAgo: 1), text: "Takk for i dag! Vi snakkes på mandag.", languageCode: "no", duration: 2, appName: "Messages"),
            HistoryEntry(date: at(16, 5, daysAgo: 1), text: "Book a table for four on Friday at seven, and ask if they have something by the window.", languageCode: "en", duration: 5, appName: "Mail"),
        ])
        let microphones = MicrophoneMonitor()
        microphones.level.simulate(0.52)
        context = AppContext(
            preferences: preferences,
            permissions: permissions,
            models: models,
            history: history,
            logger: logger,
            status: AppStatus(simulated: .ready),
            microphones: microphones,
            loginItem: LoginItem(simulatedEnabled: true),
            recorder: HotkeyRecorder(),
            output: TextOutput(preferences: preferences, logger: logger)
        )
    }
}

// MARK: Scenes

@MainActor
func settings(_ sample: Sample, page: SettingsPage) -> some View {
    let navigation = SettingsNavigation()
    navigation.page = page
    return WindowFrame(size: SettingsView.size) {
        SettingsView(context: sample.context, navigation: navigation)
    }
}

@MainActor
func onboarding(_ sample: Sample, step: OnboardingNavigation.Step, practice: Bool = false) -> some View {
    let navigation = OnboardingNavigation()
    navigation.step = step
    if practice {
        navigation.practiceText = "Testing, testing. This is the first thing I’ve dictated with VibeScribe, and it went straight into the box."
        navigation.practiceResult = HistoryEntry(text: navigation.practiceText, languageCode: "en", duration: 3.1, appName: "VibeScribe")
    }
    return WindowFrame(size: OnboardingView.size) {
        OnboardingView(context: sample.context, navigation: navigation)
    }
}

@MainActor
func overlayScene(_ phase: OverlayPhase, level: Float = 0.75) -> some View {
    let meter = LevelMeter()
    meter.simulate(level)
    let model = OverlayModel(level: meter)
    model.languageBadge = "NO"
    switch phase {
    case .listening(let handsFree): model.showListening(handsFree: handsFree, startedAt: Date().addingTimeInterval(-7.4))
    case .transcribing: model.showTranscribing()
    case .result(let result): model.show(result, for: 60)
    case .hidden: break
    }
    return ZStack(alignment: .top) {
        Wallpaper()
        VStack(spacing: 0) {
            FauxMenuBar(compact: true) { StatusItemGlyph(recording: phase == .listening(handsFree: false), title: "NO") }
            OverlayPill(phase: phase, model: model, level: level).padding(.top, 14)
            Spacer()
        }
    }
}

@MainActor
func picker(_ sample: Sample, query: String) -> some View {
    let model = LanguagePickerModel(preferences: sample.preferences)
    model.query = query
    if query.isEmpty { model.highlightIndex = 0 }
    return LanguagePickerView(model: model)
        .shadow(color: .black.opacity(0.5), radius: 20, y: 14)
}

@MainActor
func hero(_ sample: Sample, icon: NSImage?) -> some View {
    ZStack(alignment: .topLeading) {
        Wallpaper()
        VStack(spacing: 0) {
            FauxMenuBar { StatusItemGlyph(recording: true, level: 0.8, title: "0:07") }
            Spacer()
        }
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
                }
                Text("VibeScribe")
                    .font(.system(size: 64, weight: .heavy))
                    .tracking(-2)
                    .foregroundStyle(.white)
                Text("Hold a key, speak,\nand it’s pasted.")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.spectrumGradient)
                    .tracking(-0.6)
                Text("Private push-to-talk dictation for Mac. Transcribed on your Mac with WhisperKit, in 100 languages.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 420, alignment: .leading)
            }
            .padding(.leading, 80)
            .frame(width: 580, alignment: .leading)
            ZStack(alignment: .topLeading) {
                settings(sample, page: .general)
                    .scaleEffect(0.82, anchor: .topLeading)
                    .offset(x: -30, y: 190)
                MenuReplica(entry: sample.history.entries[0])
                    .scaleEffect(0.92, anchor: .topTrailing)
                    .offset(x: 540, y: 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        VStack {
            OverlayPill(phase: .listening(handsFree: false), model: {
                let model = OverlayModel(level: LevelMeter())
                model.showListening(handsFree: false, startedAt: Date().addingTimeInterval(-7.2))
                return model
            }(), level: 0.8)
            .scaleEffect(1.25)
            .padding(.top, 46)
        }
        .frame(maxWidth: .infinity)
    }
    .clipped()
}

// MARK: Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets")
    let shots = output.appendingPathComponent("screenshots")
    try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    let sample = Sample()
    let icon = NSImage(contentsOf: URL(fileURLWithPath: "Icon.png"))
    let pad: CGFloat = 60

    render(hero(sample, icon: icon), size: CGSize(width: 1440, height: 820), to: output.appendingPathComponent("hero.jpg"))

    for (page, name) in [(SettingsPage.general, "settings-general"), (.shortcut, "settings-shortcut"), (.history, "settings-history")] {
        render(
            settings(sample, page: page).padding(pad).background(Wallpaper()),
            size: CGSize(width: SettingsView.size.width + pad * 2, height: SettingsView.size.height + pad * 2),
            to: shots.appendingPathComponent("\(name).jpg")
        )
    }

    sample.models.setup(for: .largeV3Turbo).simulate(.downloading(214_000_000, 648_432_373), bytesPerSecond: 11_000_000)
    render(
        settings(sample, page: .model).padding(pad).background(Wallpaper()),
        size: CGSize(width: SettingsView.size.width + pad * 2, height: SettingsView.size.height + pad * 2),
        to: shots.appendingPathComponent("settings-model.jpg")
    )

    let setupSize = CGSize(width: OnboardingView.size.width * 2 + pad * 3, height: OnboardingView.size.height + pad * 2)
    sample.context.permissions.simulate(microphone: .authorized, inputMonitoring: .denied, accessibility: .notDetermined)
    sample.models.setup(for: .largeV3).simulate(.downloading(114_000_000, 629_481_698), bytesPerSecond: 9_000_000)
    let permissionsStep = onboarding(sample, step: .permissions)
    sample.models.setup(for: .largeV3).simulate(.downloading(308_000_000, 629_481_698), bytesPerSecond: 5_200_000)
    render(
        HStack(spacing: pad) { permissionsStep; onboarding(sample, step: .model) }.padding(pad).background(Wallpaper()),
        size: setupSize,
        to: shots.appendingPathComponent("setup.jpg")
    )
    sample.models.setup(for: .largeV3).simulate(.ready)
    sample.context.permissions.simulate(microphone: .authorized, inputMonitoring: .authorized, accessibility: .authorized)
    render(
        HStack(spacing: pad) { onboarding(sample, step: .welcome); onboarding(sample, step: .practice, practice: true) }.padding(pad).background(Wallpaper()),
        size: setupSize,
        to: shots.appendingPathComponent("setup-welcome.jpg")
    )

    render(
        ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x2B2B30)).frame(width: 520, height: 150)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Input Monitoring").font(.system(size: 15, weight: .bold))
                            Text("Allow the applications below to monitor input from your keyboard.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(18).foregroundStyle(.white)
                    }
                PermissionHelperView(kind: .inputMonitoring, appURL: URL(fileURLWithPath: "/System/Applications/Notes.app")) {}
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
            }
            .padding(.top, 40)
        },
        size: CGSize(width: 640, height: 460),
        to: shots.appendingPathComponent("permission-helper.jpg")
    )

    let overlayCell = CGSize(width: 440, height: 110)
    let phases: [OverlayPhase] = [
        .listening(handsFree: false), .listening(handsFree: true), .transcribing,
        .result(.pasted(words: 23)), .result(.copied), .result(.noSpeech),
    ]
    render(
        LazyVGrid(columns: [GridItem(.fixed(overlayCell.width), spacing: 24), GridItem(.fixed(overlayCell.width))], spacing: 24) {
            ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                overlayScene(phase)
                    .frame(width: overlayCell.width, height: overlayCell.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(28)
        .background(Color(hex: 0x1B1A22)),
        size: CGSize(width: overlayCell.width * 2 + 24 + 56, height: overlayCell.height * 3 + 48 + 56),
        to: shots.appendingPathComponent("overlay.jpg")
    )

    render(
        HStack(alignment: .top, spacing: 40) { picker(sample, query: ""); picker(sample, query: "nor") }
            .padding(50)
            .background(Wallpaper()),
        size: CGSize(width: 380 * 2 + 40 + 100, height: LanguagePickerView.size.height + 100),
        to: shots.appendingPathComponent("language-picker.jpg")
    )

    render(
        ZStack(alignment: .topTrailing) {
            Wallpaper()
            VStack(spacing: 0) {
                FauxMenuBar { StatusItemGlyph(recording: false, title: "AUTO").background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.2))) }
                HStack { Spacer(); MenuReplica(entry: sample.history.entries[0]).padding(.trailing, 120).padding(.top, 6) }
                Spacer()
            }
        },
        size: CGSize(width: 720, height: 560),
        to: shots.appendingPathComponent("menu.jpg")
    )
}
