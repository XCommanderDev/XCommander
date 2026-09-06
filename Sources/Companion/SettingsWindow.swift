import AppKit
import CompanionCore
import ServiceManagement

/// Where the app's few settings live.
///
/// Deliberately small, and the rule for what gets in is worth stating because it is what keeps
/// it small: **this window holds scalars you tune by feel.** The keymap is not here. It is a
/// hundred and forty bindings, it is a tree, and it belongs in a file you can read, diff,
/// version and share — not in a window you click through.
///
/// The layout is an `NSGridView` rather than a stack of rows. A stack was what this was first,
/// and it looked like unfinished work for a specific reason: labels and controls did not line
/// up in columns, so nothing established that the rows were the same *kind* of thing. A grid
/// gives one right-aligned column of labels and one left-aligned column of controls, which is
/// what every macOS settings window does, and why they read as a form rather than a list.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    /// Settings survive a relaunch, so they are read at launch and written on change.
    enum Key {
        static let enabled = "leaderEnabled"
        static let delay = "overlayDelay"
        static let timeout = "sequenceTimeout"
        static let leader = "leaderChoice"
    }

    /// `object(forKey:) as? Bool ?? true`, not `bool(forKey:)`. The latter returns `false` for
    /// a key that has never been written, which would ship an app that starts switched off.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    static var overlayDelay: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.delay)
            return stored > 0 ? stored : 0.35
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.delay) }
    }

    /// How long an armed sequence waits before giving up. It was a hardcoded constant with no
    /// way for a user to reach it, which is a strange thing to keep private.
    static var sequenceTimeout: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.timeout)
            return stored > 0 ? stored : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.timeout) }
    }

    /// The chosen leader, as one of the vetted options. An unknown stored value falls back to
    /// the default rather than trusting whatever happens to be in defaults.
    static var leader: LeaderChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.leader),
                  let choice = LeaderChoice(rawValue: raw) else { return .default }
            return choice
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.leader) }
    }

    var onChange: (() -> Void)?
    /// Runs the keymap check and returns a one-line verdict. Supplied by the app, because the
    /// check needs the live menu bar.
    var checkKeymap: (() -> String)?
    /// Re-reads Xcode's menu bar. A diagnostic, so it belongs here rather than in the menu.
    var rereadMenus: (() -> Void)?

    private var window: NSWindow?
    private var delayLabel: NSTextField?
    private var timeoutLabel: NSTextField?
    private var leaderNote: NSTextField?
    private var checkResult: NSTextField?

    func show() {
        if window == nil { build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // A settings window is the one place this app should come to the front properly.
        // Everything else is a non-activating panel that must never take the keyboard.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - building

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Autographe for Xcode"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(section("Leader key", grid: leaderGrid()))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(section("Timing", grid: timingGrid()))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(section("Startup", grid: startupGrid()))
        root.addArrangedSubview(separator())
        root.addArrangedSubview(section("Diagnostics", grid: diagnosticsGrid()))

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        // Size to the content rather than to a guessed rectangle, which is what left a band
        // of dead space under the old window.
        window.setContentSize(root.fittingSize)
        self.window = window
    }

    /// A titled block: a quiet header over a form grid.
    private func section(_ title: String, grid: NSGridView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(grid)
        return stack
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 424).isActive = true
        return line
    }

    private func makeGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 92
        grid.rowAlignment = .firstBaseline
        return grid
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.textColor = .secondaryLabelColor
        return field
    }

    private func value(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 310
        return field
    }

    // MARK: - sections

    private func leaderGrid() -> NSGridView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in LeaderChoice.allCases { popup.addItem(withTitle: choice.title) }
        popup.selectItem(at: LeaderChoice.allCases.firstIndex(of: Self.leader) ?? 0)
        popup.target = self
        popup.action = #selector(changeLeader(_:))

        let note = hint(Self.leader.note ?? "")
        leaderNote = note

        let enabled = NSButton(checkboxWithTitle: "Enabled while Xcode is frontmost",
                               target: self, action: #selector(toggleEnabled(_:)))
        enabled.state = Self.isEnabled ? .on : .off

        return makeGrid([
            [label("Leader"), popup],
            [NSGridCell.emptyContentView, note],
            [NSGridCell.emptyContentView, enabled],
        ])
    }

    private func timingGrid() -> NSGridView {
        let slider = NSSlider(value: Self.overlayDelay, minValue: 0.05, maxValue: 1.0,
                              target: self, action: #selector(changeDelay(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 310).isActive = true
        slider.numberOfTickMarks = 5

        let delay = value(Self.delayText())
        delayLabel = delay

        let timeoutSlider = NSSlider(value: Self.sequenceTimeout, minValue: 3, maxValue: 30,
                                     target: self, action: #selector(changeTimeout(_:)))
        timeoutSlider.translatesAutoresizingMaskIntoConstraints = false
        timeoutSlider.widthAnchor.constraint(equalToConstant: 310).isActive = true

        let timeoutValue = value(Self.timeoutText())
        timeoutLabel = timeoutValue

        return makeGrid([
            [label("Panel delay"), delay],
            [NSGridCell.emptyContentView, slider],
            [NSGridCell.emptyContentView,
             hint("Type a whole sequence faster than this and the panel never appears. "
                  + "Pause, and it answers you.")],
            [label("Give up after"), timeoutValue],
            [NSGridCell.emptyContentView, timeoutSlider],
            [NSGridCell.emptyContentView,
             hint("How long a started sequence waits for its next key before cancelling. "
                  + "The key that arrives late goes to Xcode instead.")],
        ])
    }

    private func startupGrid() -> NSGridView {
        let login = NSButton(checkboxWithTitle: "Launch at login",
                             target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        return makeGrid([
            [label("Login"), login],
            [NSGridCell.emptyContentView,
             hint("Autographe passes every key through while Xcode is not frontmost.")],
        ])
    }

    private func diagnosticsGrid() -> NSGridView {
        let check = NSButton(title: "Check keymap", target: self, action: #selector(runCheck(_:)))
        check.bezelStyle = .rounded

        let result = hint("Verifies every binding still resolves against Xcode's menus.")
        checkResult = result

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor

        let reread = NSButton(title: "Re-read Xcode's menus", target: self,
                              action: #selector(runReread(_:)))
        reread.bezelStyle = .rounded

        return makeGrid([
            [label("Keymap"), check],
            [NSGridCell.emptyContentView, result],
            [label("Menus"), reread],
            [NSGridCell.emptyContentView,
             hint("Xcode's menus are context-dependent, so the index can be built at a moment "
                  + "when half of them are absent. Rarely needed.")],
            [label("About"), versionLabel],
        ])
    }

    // MARK: - text

    private static func delayText() -> String {
        String(format: "%.0f ms", overlayDelay * 1000)
    }

    private static func timeoutText() -> String {
        String(format: "%.0f seconds", sequenceTimeout)
    }

    // MARK: - actions

    @objc private func toggleEnabled(_ sender: NSButton) {
        Self.isEnabled = sender.state == .on
        onChange?()
    }

    @objc private func changeLeader(_ sender: NSPopUpButton) {
        let choice = LeaderChoice.allCases[sender.indexOfSelectedItem]
        Self.leader = choice
        leaderNote?.stringValue = choice.note ?? ""
        onChange?()
    }

    @objc private func changeDelay(_ sender: NSSlider) {
        Self.overlayDelay = sender.doubleValue
        delayLabel?.stringValue = Self.delayText()
        onChange?()
    }

    @objc private func changeTimeout(_ sender: NSSlider) {
        Self.sequenceTimeout = sender.doubleValue.rounded()
        timeoutLabel?.stringValue = Self.timeoutText()
        onChange?()
    }

    /// The keymap check used to report only to the system log, where no user would ever look
    /// for it. A binding that has gone dead because Xcode renamed a menu item is exactly the
    /// kind of thing a person needs told.
    @objc private func runReread(_ sender: NSButton) {
        rereadMenus?()
        checkResult?.stringValue = "Re-read Xcode's menus."
    }

    @objc private func runCheck(_ sender: NSButton) {
        checkResult?.stringValue = checkKeymap?() ?? "unavailable"
    }

    /// `SMAppService` is the supported route since macOS 13; the old login-items API is
    /// deprecated and the `LaunchAgents` plist route is not appropriate for a normal app.
    @objc private func toggleLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            NSAlert(error: error).runModal()
        }
    }
}
