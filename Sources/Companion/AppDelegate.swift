import AppKit
import ApplicationServices
import CompanionCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let context = AccessibilityXcodeContext()
    private var session = KeymapSession(leader: DefaultKeymap.leader, keymap: DefaultKeymap.build())
    private var executor: CommandExecutor!
    private var overlay: OverlayController!
    private var tap: EventTap!
    private var menuBar: MenuBarController!

    /// Cached rather than asked for on the keystroke path. `NSWorkspace` is cheap in steady
    /// state but has an 850 µs tail, and the notification is free and has none.
    private var xcodeIsFrontmost = false
    private var hasAccessibility = false
    private var accessibilityPollTimer: Timer?

    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        executor = CommandExecutor(context: context)
        executor.onCompanionCommand = { [weak self] id in self?.runCompanionCommand(id) }
        overlay = OverlayController(context: context)
        menuBar = MenuBarController()
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onReloadMenus = { [weak self] in self?.context.refreshMenuIndex() }
        menuBar.onOpenAccessibilitySettings = { Self.openAccessibilitySettings() }

        tap = EventTap(
            handler: { [weak self] keyCode, flags in
                self?.handleKey(keyCode: keyCode, flags: flags) ?? false
            },
            onInterrupted: { [weak self] in self?.abandonSequence() },
            onSecureInputChanged: { [weak self] _ in self?.updateStatus() }
        )

        observeFrontmostApplication()
        xcodeIsFrontmost = context.isFrontmost
        requestAccessibilityThenStart()
    }

    // MARK: - The keystroke path

    /// Called from the tap callback. Everything here is a dictionary lookup or better;
    /// nothing asks the system anything.
    private func handleKey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard xcodeIsFrontmost else { return false }
        guard let event = EventBridge.keyEvent(keyCode: keyCode, flags: flags) else { return false }

        let outcome = session.press(event)
        switch outcome {
        case .passThrough:
            break
        case .awaiting(let panel):
            overlay.present(annotated(panel))
        case .fired(let command):
            overlay.dismiss()
            // Posting a synthetic event from inside the tap callback would have us
            // re-enter our own tap before this one has returned. Run it on the next turn
            // of the run loop, when the callback is off the stack.
            DispatchQueue.main.async { [weak self] in self?.run(command) }
        case .cancelled(let reason):
            overlay.dismiss()
            if case .unbound(let key) = reason {
                log.debug("no binding for \(key.display, privacy: .public)")
            }
        }
        return outcome.swallowsKey
    }

    /// Fill in each row's native Xcode shortcut from the live menu index, so the panel
    /// teaches the built-in binding alongside ours. Core cannot do this: what `Product >
    /// Build` is bound to depends on the running Xcode and the user's keyboard layout.
    private func annotated(_ panel: WhichKeyPanel) -> WhichKeyPanel {
        var panel = panel
        for i in panel.rows.indices {
            guard let path = panel.rows[i].menuPath else { continue }
            guard let item = context.menuItem(at: path) else {
                log.debug("annotate: no menu item for \(path.joined(separator: " > "), privacy: .public)")
                continue
            }
            log.debug("annotate: \(path.joined(separator: " > "), privacy: .public) -> \(item.shortcut?.display ?? "nil", privacy: .public)")
            panel.rows[i].shortcut = item.shortcut?.display
        }
        return panel
    }

    private func run(_ command: Command) {
        let result = executor.run(command)
        switch result {
        case .posted(let key):
            log.debug("\(command.id, privacy: .public) via shortcut \(key.display, privacy: .public)")
        case .pressed(let path):
            log.debug("\(command.id, privacy: .public) via menu \(path.joined(separator: " > "), privacy: .public)")
        case .handledInternally:
            break
        case .unavailable(let why):
            log.notice("\(command.id, privacy: .public): \(why, privacy: .public)")
            NSSound.beep()
        }
    }

    private func runCompanionCommand(_ id: String) {
        switch id {
        case "quit": NSApp.terminate(nil)
        case "reloadMenus": context.refreshMenuIndex()
        default: log.error("unknown companion command \(id, privacy: .public)")
        }
    }

    /// §8 question 2: every way a sequence can be abandoned ends here, and they all reset
    /// the same way — an app switch, a disabled tap, secure input starting.
    private func abandonSequence() {
        if session.abandon() != nil { overlay.dismiss() }
    }

    // MARK: - Permission and lifecycle

    private func requestAccessibilityThenStart() {
        hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility {
            start()
            return
        }
        // Prompts once, then the user has to grant it in System Settings. Poll until they
        // do rather than asking them to relaunch.
        // The constant is imported as a mutable global, which Swift 6 will not let us
        // touch. Its value is stable and documented, so use the string directly.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        updateStatus()

        // The timer is held in a property rather than captured: `Timer` is not Sendable,
        // so it cannot cross into the isolated closure, but `self` already can.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.hasAccessibility = true
                self.start()
            }
        }
        accessibilityPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func start() {
        guard tap.install() else {
            log.error("could not install the event tap")
            updateStatus()
            return
        }
        KeyboardLayout.refreshIfNeeded()
        log.notice("layout: \(KeyboardLayout.currentLayoutName(), privacy: .public)")
        if context.isRunning { context.refreshMenuIndex() }
        updateStatus()
    }

    private func observeFrontmostApplication() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            // Read the one value we need out of the notification here: `Notification` is
            // not Sendable, a `String?` is.
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                let nowFrontmost = bundleID == "com.apple.dt.Xcode"
                if self.xcodeIsFrontmost && !nowFrontmost { self.abandonSequence() }
                self.xcodeIsFrontmost = nowFrontmost
                // A newly launched Xcode is a new process, so the cached menu elements are
                // stale. Reading them again costs ~750 ms and only happens on activation.
                if nowFrontmost && self.hasAccessibility { self.context.refreshMenuIndex() }
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        let status = CompanionStatus.derive(hasAccessibility: hasAccessibility,
                                            secureInputActive: tap.secureInputActive,
                                            xcodeFrontmost: xcodeIsFrontmost)
        // Logged at notice level, and only on a change. A menu-bar glyph is four pixels of
        // signal; when the leader key "just stops working" this is what says why, and it
        // was the missing piece the one time that happened during development.
        if status != menuBar.status {
            log.notice("status -> \(String(describing: status), privacy: .public)")
        }
        menuBar.apply(status)
    }

    private static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
