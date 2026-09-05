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

    /// The pens from the app icon, knocked out of their tile, as a **template** image —
    /// the idiomatic menu-bar image on macOS. The system discards a template's colours and
    /// uses its alpha as a mask, so the mark goes black on a light bar, white on a dark one,
    /// and tints under a tinted wallpaper, the way Alfred's hat does.
    ///
    /// The *whole* app icon can never do this. A template's alpha is its shape, and the
    /// icon's alpha is a filled rounded rectangle, so it renders as a blank white square.
    /// The pens on their own are a silhouette, which is exactly what a template wants —
    /// `Design/autographe-v1.svg` keeps them in their own groups so `tools/icons.sh` can
    /// render them without the tile.
    private func brandMark(opacity: CGFloat, description: String) -> NSImage? {
        guard let mark = NSImage(named: "MenuBarMark") else { return nil }
        guard opacity < 1 else {
            mark.isTemplate = true
            mark.accessibilityDescription = description
            return mark
        }
        // A template's mask can be partly transparent, so dimming the alpha dims the tint —
        // the mark stays the bar's colour and simply recedes. Drawn through a handler rather
        // than `lockFocus` so it re-renders per context and stays right on both scales.
        let dimmed = NSImage(size: mark.size, flipped: false) { rect in
            mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            return true
        }
        dimmed.isTemplate = true
        dimmed.accessibilityDescription = description
        return dimmed
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func quit() { onQuit?() }
    @objc private func reload() { onReloadMenus?() }
    @objc private func openSettings() { onOpenAccessibilitySettings?() }
}
