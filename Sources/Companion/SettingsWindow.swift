import AppKit
import CompanionCore
import ServiceManagement

/// Where the app's few settings live.
///
/// Deliberately small. The keymap is not here: it is a hundred bindings and it belongs in a
/// file you can read and version, not in a window you have to click through. What is here is
/// what you would otherwise have to rebuild the app to change.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {

    /// Settings survive a relaunch, so they are read at launch and written on change.
    enum Key {
        static let enabled = "leaderEnabled"
        static let delay = "overlayDelay"
    }

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    static var overlayDelay: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: Key.delay)
            return stored > 0 ? stored : 0.35
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.delay) }
    }

    var onChange: (() -> Void)?

    private var window: NSWindow?
    private var delayLabel: NSTextField?

    func show() {
        if window == nil { build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // A settings window is the one place this app should come to the front properly.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Autographe for Xcode"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let leader = NSTextField(labelWithString: "Leader key       \(DefaultKeymap.leader.display)")
        leader.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(leader)

        let enabled = NSButton(checkboxWithTitle: "Leader key enabled",
                               target: self, action: #selector(toggleEnabled(_:)))
        enabled.state = Self.isEnabled ? .on : .off
        stack.addArrangedSubview(enabled)

        let login = NSButton(checkboxWithTitle: "Launch at login",
                             target: self, action: #selector(toggleLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stack.addArrangedSubview(login)

        let label = NSTextField(labelWithString: Self.delayText())
        label.font = .systemFont(ofSize: 12)
        delayLabel = label
        stack.addArrangedSubview(label)

        let slider = NSSlider(value: Self.overlayDelay, minValue: 0.05, maxValue: 1.0,
                              target: self, action: #selector(changeDelay(_:)))
        slider.frame.size.width = 360
        stack.addArrangedSubview(slider)

        let hint = NSTextField(wrappingLabelWithString:
            "Type a whole sequence faster than the delay and the panel never appears. "
            + "Pause, and it answers you.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(hint)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let about = NSTextField(labelWithString: "Version \(version)")
        about.font = .systemFont(ofSize: 11)
        about.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(about)

        window.contentView = stack
        self.window = window
    }

    private static func delayText() -> String {
        String(format: "Overlay delay      %.0f ms", overlayDelay * 1000)
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        Self.isEnabled = sender.state == .on
        onChange?()
    }

    @objc private func changeDelay(_ sender: NSSlider) {
        Self.overlayDelay = sender.doubleValue
        delayLabel?.stringValue = Self.delayText()
        onChange?()
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
