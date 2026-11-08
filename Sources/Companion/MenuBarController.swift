import AppKit
import XcodeMenus
import XCommanderCore

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
    /// The pre-filled bug report page. Supplied by the app, which knows which Xcode is running.
    var bugReportURL: (() -> URL)?

    /// A **noun with a checkmark**, not a flipping verb.
    ///
    /// This used to do both: the title flipped between `Enable`/`Disable` *and* the item
    /// carried a checkmark. "✓ Disable Leader Key" reads as "disabling is on" — the exact
    /// opposite of what it meant. macOS gives you two idioms and they are mutually exclusive:
    /// a verb that flips and carries no state, or a static noun whose checkmark is the state.
    /// The noun is better here because it also reads as an indicator at a glance.
    private let enabledEntry = NSMenuItem(title: "Leader Key", action: nil, keyEquivalent: "")
    private let permissionsEntry = NSMenuItem(title: "Open Accessibility Settings…",
                                              action: nil, keyEquivalent: "")
    private let permissionsSeparator = NSMenuItem.separator()

    /// Name and version, the way Alfred and most menu-bar apps carry it: dimmed, directly
    /// under the status. It is not decoration — it is the first thing you ask a user in a
    /// support conversation, and the menu is the only place they can read it without hunting
    /// through a settings window.
    private let versionEntry = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// "Update available: 0.2.0". Hidden until the update check finds something, and then it's
    /// a link to the release page: it never downloads anything itself.
    private let updateEntry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var updatePage: URL?

    /// Shown next to the status line so the one thing a new user needs to know — which key
    /// starts everything — is visible without reading any documentation. Discovery is this
    /// app's largest risk; the menu is the only surface it has to spend on it.
    var leaderDisplay: String = "" { didSet { apply(status, force: true) } }

    private(set) var status: CompanionStatus = .idle
    fileprivate let xcodeChangesEntry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    fileprivate let xcodeChangesSeparator = NSMenuItem.separator()

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()

        // The primary action first, then a dimmed line saying what is going on: the shape
        // Alfred and most good menu-bar apps use. Everything that is not one of those two
        // things, or Settings, or Quit, has been moved into the settings window — a menu
        // that repeats the settings window is just a second place to look.
        enabledEntry.action = #selector(toggleEnabled)
        enabledEntry.target = self
        menu.addItem(enabledEntry)

        statusEntry.isEnabled = false
        menu.addItem(statusEntry)

        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        versionEntry.title = build.map { "XCommander \(short) (\($0))" } ?? "XCommander \(short)"
        versionEntry.isEnabled = false
        menu.addItem(versionEntry)

        updateEntry.action = #selector(openUpdatePage)
        updateEntry.target = self
        updateEntry.isHidden = true
        menu.addItem(updateEntry)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Opens GitHub's bug report form with the versions already filled in, because "which
        // Xcode?" is the first question every report needs answered.
        let report = NSMenuItem(title: "Report a Bug…", action: #selector(reportBug), keyEquivalent: "")
        report.target = self
        menu.addItem(report)

        // **Kept, but only when it is the answer to something.** This is the one item that
        // cannot live in the settings window: with no Accessibility permission the app sees
        // no keys, so the menu is the only surface a user has. It is hidden in every other
        // state, which is what keeps the ordinary menu to three items.
        // Same rule as the permissions entry: present only when it is the answer to
        // something. Xcode changing under the user is news exactly once per Xcode, and a
        // line they can ignore beats a sheet they must dismiss.
        xcodeChangesEntry.action = #selector(openXcodeChanges)
        xcodeChangesEntry.target = self
        xcodeChangesSeparator.isHidden = true
        xcodeChangesEntry.isHidden = true
        menu.addItem(xcodeChangesSeparator)
        menu.addItem(xcodeChangesEntry)

        permissionsEntry.action = #selector(openSettings)
        permissionsEntry.target = self
        permissionsSeparator.isHidden = true
        permissionsEntry.isHidden = true
        menu.addItem(permissionsSeparator)
        menu.addItem(permissionsEntry)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        apply(.idle)
    }

    func apply(_ status: CompanionStatus) { apply(status, force: false) }

    private func apply(_ status: CompanionStatus, force: Bool) {
        guard force || status != self.status || item.button?.image == nil else { return }
        self.status = status
        item.button?.image = image(for: status)
        item.button?.toolTip = status.explanation
        // When the leader is live, say what it is. "Ready." tells a new user nothing they
        // can act on; "Ready — press ⌥RET" tells them the only thing they need.
        statusEntry.title = status == .armed && !leaderDisplay.isEmpty
            ? "Ready — press \(leaderDisplay)"
            : status.explanation

        let needsPermission = status == .needsAccessibility
        permissionsEntry.isHidden = !needsPermission
        permissionsSeparator.isHidden = !needsPermission
    }

    /// Reflect the on/off state in the menu, so the item reads as a switch rather than a
    /// command whose effect you have to remember.
    func setEnabled(_ enabled: Bool) {
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

    /// The hat from the app icon, without its tile, as a **template** image — the idiomatic
    /// menu-bar image on macOS. The system discards a template's colours and uses its alpha
    /// as a mask, so the mark goes black on a light bar, white on a dark one, and tints under
    /// a tinted wallpaper.
    ///
    /// The *whole* app icon can never do this. A template's alpha is its shape, and the
    /// icon's alpha is a filled rounded rectangle, so it renders as a blank white square.
    /// `xcdev icons` renders the hat from `Graphics/X-hat-black-on-white2.svg` and cuts the
    /// light ⌘ and crossbones out of it, so the bar draws them in its own colour.
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
    @objc private func openUpdatePage() { if let updatePage { NSWorkspace.shared.open(updatePage) } }
    @objc private func reportBug() { if let url = bugReportURL?() { NSWorkspace.shared.open(url) } }

    /// Show the update line. Called by `UpdateChecker` when GitHub has a newer release.
    func announceUpdate(version: String, page: URL) {
        updateEntry.title = "Update Available: \(version)…"
        updatePage = page
        updateEntry.isHidden = false
    }
    @objc private func showSettings() { onShowSettings?() }
    @objc private func quit() { onQuit?() }
    @objc private func reload() { onReloadMenus?() }
    @objc private func openSettings() { onOpenAccessibilitySettings?() }
}

extension MenuBarController {

    /// Show, or clear, the one line that says Xcode changed underneath the user.
    ///
    /// Clicking it opens the Markdown report rather than showing a sheet: the report is a
    /// file in their config directory, which is where this audience already keeps things
    /// they want to read on their own terms.
    func announceXcodeChanges(_ summary: String?) {
        guard let summary else {
            xcodeChangesEntry.isHidden = true
            xcodeChangesSeparator.isHidden = true
            return
        }
        xcodeChangesEntry.title = summary
        xcodeChangesEntry.toolTip = "Open \(ChangeReport.url.path)"
        xcodeChangesEntry.isHidden = false
        xcodeChangesSeparator.isHidden = false
    }

    @objc fileprivate func openXcodeChanges() {
        NSWorkspace.shared.open(ChangeReport.url)
    }
}
