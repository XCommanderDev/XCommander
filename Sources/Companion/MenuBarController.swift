import AppKit
import CompanionCore

/// The status item. Small, but it is the only surface the app has when something is wrong,
/// so it says *why* rather than just going quiet.
@MainActor
final class MenuBarController {

    private let item: NSStatusItem
    private let statusEntry = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    var onQuit: (() -> Void)?
    var onReloadMenus: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onToggleEnabled: (() -> Void)?
    var onShowSettings: (() -> Void)?

    private let enabledEntry = NSMenuItem(title: "Enable Leader Key", action: nil, keyEquivalent: "")

    private(set) var status: CompanionStatus = .idle

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusEntry.isEnabled = false
        menu.addItem(statusEntry)
        menu.addItem(.separator())

        enabledEntry.action = #selector(toggleEnabled)
        enabledEntry.target = self
        menu.addItem(enabledEntry)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let permissions = NSMenuItem(title: "Open Accessibility Settings…",
                                     action: #selector(openSettings), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        let reload = NSMenuItem(title: "Reload Xcode Commands",
                                action: #selector(reload), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        apply(.idle)
    }

    func apply(_ status: CompanionStatus) {
        guard status != self.status || item.button?.image == nil else { return }
        self.status = status
        let glyph = NSImage(systemSymbolName: status.menuBarSymbol,
                            accessibilityDescription: status.explanation)
        // A template image is drawn using the menu bar's own colour, so it stays legible
        // in light and dark and while the bar is tinted by the wallpaper. SF Symbols are
        // templates already; saying so keeps that true if this is ever a custom image.
        glyph?.isTemplate = true
        item.button?.image = glyph
        item.button?.toolTip = status.explanation
        statusEntry.title = status.explanation
    }

    /// Reflect the on/off state in the menu, so the item reads as a switch rather than a
    /// command whose effect you have to remember.
    func setEnabled(_ enabled: Bool) {
        enabledEntry.title = enabled ? "Disable Leader Key" : "Enable Leader Key"
        enabledEntry.state = enabled ? .on : .off
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func quit() { onQuit?() }
    @objc private func reload() { onReloadMenus?() }
    @objc private func openSettings() { onOpenAccessibilitySettings?() }
}
