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

    private(set) var status: CompanionStatus = .idle

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        statusEntry.isEnabled = false
        menu.addItem(statusEntry)
        menu.addItem(.separator())

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
        item.button?.image = NSImage(systemSymbolName: status.menuBarSymbol,
                                     accessibilityDescription: status.explanation)
        item.button?.toolTip = status.explanation
        statusEntry.title = status.explanation
    }

    @objc private func quit() { onQuit?() }
    @objc private func reload() { onReloadMenus?() }
    @objc private func openSettings() { onOpenAccessibilitySettings?() }
}
