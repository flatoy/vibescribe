import AppKit
import ServiceManagement

enum Sounds {
    enum Cue {
        case start
        case stop
    }

    @MainActor
    static func play(_ cue: Cue) {
        let name = cue == .start ? "Tink" : "Pop"
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}

/// Open at login, through the system's login items.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false

    /// Login items only work for the packaged app, not `swift run`.
    let isAvailable: Bool
    private let simulated: Bool

    init() {
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
        simulated = false
        refresh()
    }

    /// For previews and README screenshots.
    init(simulatedEnabled: Bool) {
        isAvailable = true
        simulated = true
        isEnabled = simulatedEnabled
    }

    func refresh() {
        guard !simulated else { return }
        isEnabled = isAvailable && SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool, logger: Logger) {
        guard isAvailable, !simulated else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.append("Could not change Open at login: \(error.localizedDescription)", level: .error)
        }
        refresh()
    }
}

enum SystemSettings {
    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
        case storage = "storage"
    }

    /// Called whenever VibeScribe sends someone to a privacy pane, so a helper can follow.
    @MainActor static var didOpen: ((Pane) -> Void)?

    @MainActor
    static func open(_ pane: Pane) {
        didOpen?(pane)
        let url: URL
        if pane == .storage {
            url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
        } else {
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        }
        NSWorkspace.shared.open(url)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "development build" }
        return short
    }

    static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    static var licensesFolder: URL {
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            return resources.appendingPathComponent("Licenses", isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/VibeScribe/Resources/Licenses", isDirectory: true)
    }
}
