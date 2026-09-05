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
        item.button?.image = image(for: status)
        item.button?.toolTip = status.explanation
        statusEntry.title = status.explanation
    }

    /// Reflect the on/off state in the menu, so the item reads as a switch rather than a
    /// command whose effect you have to remember.
    func setEnabled(_ enabled: Bool) {
        enabledEntry.title = enabled ? "Disable Leader Key" : "Enable Leader Key"
        enabledEntry.state = enabled ? .on : .off
    }

    /// The app's own mark when everything is fine, a system glyph when it is not.
    ///
    /// Alfred shows its hat as a **template** image — macOS throws away the colours and uses
    /// the alpha as a mask, which works because the hat's transparency *is* its shape. Our
    /// mark is a filled tile, so its alpha is a rounded rectangle: as a template it would be
    /// a blank white square. So it is drawn in colour, which macOS allows and plenty of apps
    /// do.
    ///
    /// The two states that need attention keep an SF Symbol. A tinted brand mark is a poor
    /// way to say "your keyboard has stopped working"; a padlock and a warning triangle are
    /// unmistakable, and being off-brand for a moment is the point of them.
    private func image(for status: CompanionStatus) -> NSImage? {
        if let symbol = status.faultSymbol {
            let glyph = NSImage(systemSymbolName: symbol,
                                accessibilityDescription: status.explanation)
            glyph?.isTemplate = true
            return glyph
        }
        // Dimmed when the leader is not live, so the bar shows at a glance whether a
        // keystroke would do anything.
        let opacity: CGFloat = status == .armed ? 1.0 : 0.45
        return brandMark(opacity: opacity, description: status.explanation)
    }

    /// The app icon, drawn down to menu-bar size. Taken from `applicationIconImage` rather
    /// than a second asset, so it follows whatever icon the bundle actually ships.
    private func brandMark(opacity: CGFloat, description: String) -> NSImage? {
        guard let icon = NSApp.applicationIconImage else { return nil }
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: opacity)
        image.unlockFocus()
        // Not a template: the colours are the point.
        image.isTemplate = false
        image.accessibilityDescription = description
        return image
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func quit() { onQuit?() }
    @objc private func reload() { onReloadMenus?() }
    @objc private func openSettings() { onOpenAccessibilitySettings?() }
}
