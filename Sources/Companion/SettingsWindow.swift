import AppKit
import XCommanderCore
import ServiceManagement
import SwiftUI

/// Where the app's few settings live.
///
/// Deliberately small, and the rule for what gets in is worth stating because it is what keeps
/// it small: **this window holds scalars you tune by feel.** The keymap is not here. It is a
/// hundred and forty bindings, it is a tree, and it belongs in a file you can read, diff,
/// version and share — not in a window you click through.
///
/// The window is built from both frameworks, and the seam between them is the point:
///
/// - **AppKit owns the chrome.** `NSTabViewController` in `.toolbar` style *is* the macOS
///   settings window — the icon toolbar, the title that follows the selected pane, and the
///   window resizing itself as you move between panes of different heights. Rebuilding that
///   in SwiftUI outside a `Settings` scene means reimplementing all three, badly.
/// - **SwiftUI owns the panes.** Each one is a stack of labelled controls bound to
///   `UserDefaults`, which is what `Form` and `@AppStorage` describe. There is nothing to
///   hand-build and nothing to keep in sync.
///
/// Which is the same rule the rest of the app follows, applied one level down: the parts with
/// platform behaviour to inherit are AppKit, and the parts that are just controls over stored
/// values are SwiftUI.
@MainActor
final class SettingsWindow {

    /// Settings survive a relaunch, so they are read at launch and written on change.
    enum Key {
        static let enabled = "leaderEnabled"
        static let delay = "overlayDelay"
        static let timeout = "sequenceTimeout"
        static let leader = "leaderChoice"
        static let preview = "pickerPreview"
    }

    /// The accessors below are what the rest of the app reads; the panes bind to the same keys
    /// through `@AppStorage`. Two doors onto one store, which is why the defaults have to
    /// agree — each pair is written next to the other so a change to one is a change to both.
    ///
    /// `object(forKey:) as? Bool ?? true`, not `bool(forKey:)`. The latter returns `false` for
    /// a key that has never been written, which would ship an app that starts switched off.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    static let defaultOverlayDelay = 0.35

    static var overlayDelay: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.delay)
            return stored > 0 ? stored : defaultOverlayDelay
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.delay) }
    }

    static let defaultSequenceTimeout = 10.0

    /// How long an armed sequence waits before giving up. It was a hardcoded constant with no
    /// way for a user to reach it, which is a strange thing to keep private.
    static var sequenceTimeout: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.timeout)
            return stored > 0 ? stored : defaultSequenceTimeout
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.timeout) }
    }

    /// Whether the pickers show a preview pane. Same guarded read as the leader: an unknown
    /// stored value falls back rather than being trusted.
    static var previewMode: PreviewMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.preview),
                  let mode = PreviewMode(rawValue: raw) else { return .default }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.preview) }
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
    /// Re-reads the config file and reports what it said. The one place a user will look
    /// when their `config.toml` does not seem to have taken effect.
    var configSummary: (() -> String)?

    private var window: NSWindow?

    func show() {
        if window == nil { build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // A settings window is the one place this app should come to the front properly.
        // Everything else is a non-activating panel that must never take the keyboard.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let notify: () -> Void = { [weak self] in self?.onChange?() }

        let tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        tabs.addTab(GeneralPane(onChange: notify),
                    label: "General", symbol: "gearshape")
        tabs.addTab(TimingPane(onChange: notify),
                    label: "Timing", symbol: "timer")
        tabs.addTab(DiagnosticsPane(
                        checkKeymap: { [weak self] in self?.checkKeymap?() ?? "unavailable" },
                        rereadMenus: { [weak self] in self?.rereadMenus?() },
                        checkConfig: { [weak self] in self?.configSummary?() ?? "unavailable" }),
                    label: "Diagnostics", symbol: "stethoscope")

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.window = window
    }
}

/// The classic settings container: an icon toolbar over one pane at a time.
///
/// The subclass exists for one line. `NSTabViewController` gives the toolbar and the resizing
/// for free, but not the title — and a settings window whose title never changes is the tell
/// that it is not really a settings window.
@MainActor
private final class SettingsTabController: NSTabViewController {

    /// Each pane sizes itself, which is what lets the window shrink to the Timing pane and
    /// grow again for Diagnostics rather than padding every pane out to the tallest one.
    func addTab(_ pane: some View, label: String, symbol: String) {
        let controller = NSHostingController(rootView: pane)
        controller.sizingOptions = [.preferredContentSize]
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        view.window?.title = item?.label ?? "Settings"
    }
}

// MARK: - panes

private struct GeneralPane: View {

    let onChange: () -> Void

    @AppStorage(SettingsWindow.Key.enabled) private var isEnabled = true
    @AppStorage(SettingsWindow.Key.leader) private var leader = LeaderChoice.default
    @AppStorage(SettingsWindow.Key.preview) private var preview = PreviewMode.default

    /// Not a stored setting: the login item lives in `SMAppService`, and this mirrors it.
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Leader") {
                    // Every leader shadows something, and a settings window that presents
                    // five options as though they were free is how a user ends up confused
                    // a week later.
                    Explained(leader.note) {
                        Picker("Leader", selection: $leader) {
                            ForEach(LeaderChoice.allCases, id: \.self) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150, alignment: .leading)
                    }
                }
                Toggle("Enabled while Xcode is frontmost", isOn: $isEnabled)

                // Three states rather than a switch, because the panel grows downward to
                // make room and a short Xcode window cannot take it. See `PreviewMode`.
                LabeledContent("Preview") {
                    Explained(preview.note) {
                        Picker("Preview", selection: $preview) {
                            ForEach(PreviewMode.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 230, alignment: .leading)
                    }
                }
            }

            Section {
                // The hint is an argument for the switch, not a description of it: it answers
                // "is it safe to let this run all the time", which is the actual question.
                Explained("XCommander passes every key through while Xcode is not frontmost.") {
                    Toggle("Launch at login", isOn: $launchesAtLogin)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width)
        .onChange(of: isEnabled) { _, _ in onChange() }
        .onChange(of: leader) { _, _ in onChange() }
        .onChange(of: launchesAtLogin) { _, wanted in setLoginItem(wanted) }
        .alert("Could not change the login item", isPresented: showingLoginError) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
    }

    private var showingLoginError: Binding<Bool> {
        Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })
    }

    /// `SMAppService` is the supported route since macOS 13; the old login-items API is
    /// deprecated and the `LaunchAgents` plist route is not appropriate for a normal app.
    ///
    /// The toggle goes back if the call fails, because the switch is a claim about system
    /// state and the system has just declined to make it true.
    private func setLoginItem(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = error.localizedDescription
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct TimingPane: View {

    let onChange: () -> Void

    @AppStorage(SettingsWindow.Key.delay) private var overlayDelay
        = SettingsWindow.defaultOverlayDelay
    @AppStorage(SettingsWindow.Key.timeout) private var sequenceTimeout
        = SettingsWindow.defaultSequenceTimeout

    var body: some View {
        Form {
            Section {
                LabeledContent("Panel delay") {
                    Explained("Type a whole sequence faster than this and the panel never "
                              + "appears. Pause, and it answers you.") {
                        Metered(text: delayText) {
                            Slider(value: $overlayDelay, in: 0.05...1.0)
                        }
                    }
                }
                LabeledContent("Give up after") {
                    Explained("How long a started sequence waits for its next key before "
                              + "cancelling. The key that arrives late goes to Xcode instead.") {
                        Metered(text: timeoutText) {
                            Slider(value: $sequenceTimeout, in: 3...30, step: 1)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width)
        .onChange(of: overlayDelay) { _, _ in onChange() }
        .onChange(of: sequenceTimeout) { _, _ in onChange() }
    }

    private var delayText: String { String(format: "%.0f ms", overlayDelay * 1000) }

    private var timeoutText: String { String(format: "%.0f seconds", sequenceTimeout) }
}

private struct DiagnosticsPane: View {

    let checkKeymap: () -> String
    let rereadMenus: () -> Void
    let checkConfig: () -> String

    @State private var result = "Verifies every binding still resolves against Xcode's menus."
    @State private var configResult =
        "Re-reads ~/.config/xcommander/config.toml and reports what it said."

    var body: some View {
        Form {
            Section {
                LabeledContent("Keymap") {
                    // The keymap check used to report only to the system log, where no user
                    // would ever look for it. A binding that has gone dead because Xcode
                    // renamed a menu item is exactly the thing a person needs told.
                    Explained(result) {
                        Button("Check keymap") { result = checkKeymap() }
                    }
                }
                LabeledContent("Menus") {
                    Explained("Xcode's menus are context-dependent, so the index can be built "
                              + "at a moment when half of them are absent. Rarely needed.") {
                        Button("Re-read Xcode's menus") {
                            rereadMenus()
                            result = "Re-read Xcode's menus."
                        }
                    }
                }
            }
            Section {
                LabeledContent("Config file") {
                    // A config error has to be reachable from the app, not only from the
                    // log: "I saved and nothing happened" is the failure mode of every
                    // hot-reloading file, and this is the answer to it.
                    Explained(configResult) {
                        Button("Check config") { configResult = checkConfig() }
                    }
                }
            }
            Section {
                LabeledContent("XCommander", value: version)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsMetrics.width)
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }
}

// MARK: - shared

private enum SettingsMetrics {
    /// One width for every pane, so the window does not jump sideways as you change tab.
    /// Only the height is allowed to differ.
    static let width: CGFloat = 440
}

/// A control and the line that explains it, kept inside a **single** form row.
///
/// This is the one thing worth knowing about building a settings pane this way. A grouped
/// `Form` gives every row the same generous padding, so a hint written as its own row costs a
/// full row of it — the first version of this window, with three rows per setting, opened at
/// 939 points tall and was most of the way to unusable. The hint belongs to its control;
/// saying so in the view tree is what makes the pane the right size, and it is better
/// structure anyway.
private struct Explained<Content: View>: View {
    private let hint: String?
    private let content: Content

    init(_ hint: String?, @ViewBuilder content: () -> Content) {
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            content
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A slider with its current value beside it, in a fixed column so the number does not shove
/// the slider around as it goes from "50 ms" to "1000 ms".
private struct Metered<Content: View>: View {
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) {
            content
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
    }
}
