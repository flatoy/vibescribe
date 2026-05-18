import AppKit
import Combine

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let preferences: Preferences
    private var cancellables = Set<AnyCancellable>()

    private let openMainAction: () -> Void
    private let quitAction: () -> Void

    init(
        preferences: Preferences,
        onOpenMain: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.preferences = preferences
        self.openMainAction = onOpenMain
        self.quitAction = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VibeScribe")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }

        updateFlagTitle(for: preferences.deepgramLanguage)

        preferences.$deepgramLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] language in
                self?.updateFlagTitle(for: language)
            }
            .store(in: &cancellables)

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Settings", action: #selector(openMainWindow), keyEquivalent: ",")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func updateFlagTitle(for language: DeepgramLanguage) {
        statusItem.button?.title = " " + language.flag
    }

    @objc private func openMainWindow() {
        openMainAction()
    }

    @objc private func quitApp() {
        quitAction()
    }
}
