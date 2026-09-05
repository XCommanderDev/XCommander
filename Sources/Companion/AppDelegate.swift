import AppKit
import ApplicationServices
import CompanionCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let context = AccessibilityXcodeContext()
    private var registry = CommandRegistry()
    private var session: KeymapSession!
    private var executor: CommandExecutor!
    private var whichKey: OverlayController!
    private var picker: PickerOverlay!
    private var tap: EventTap!
    private var menuBar: MenuBarController!

    /// Exactly one of these is active at a time. The keymap session drives the which-key
    /// panel; a picker, once open, takes every key until it is chosen or cancelled.
    private var activePicker: PickerSession?
    private var fileIndex = FileIndex()
    private var history = DocumentHistory()
    private var tracker: WindowTracker!

    private var xcodeIsFrontmost = false
    private var hasAccessibility = false
    private var accessibilityPollTimer: Timer?

    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let built = DefaultKeymap.build()
        registry = built.registry
        session = KeymapSession(leader: DefaultKeymap.leader,
                                keymap: built.keymap,
                                registry: built.registry)
        // The panel shows each command's live Xcode shortcut, which depends on the running
        // Xcode and the user's layout, so Core is handed a closure rather than a table.
        session.shortcutProvider = { [weak self] command in
            guard let self, let path = command.menuPath else { return nil }
            return MainActor.assumeIsolated { self.context.menuItem(at: path)?.shortcut?.display }
        }

        executor = CommandExecutor(context: context)
        executor.onCompanionCommand = { [weak self] id in self?.runCompanionCommand(id) }
        whichKey = OverlayController(context: context)
        picker = PickerOverlay(context: context)

        // Both overlays follow Xcode's window, and the buffer list is fed by watching which
        // document has focus.
        tracker = WindowTracker(context: context)
        tracker.onGeometryChanged = { [weak self] in
            self?.whichKey.followWindow()
            self?.picker.followWindow()
        }
        tracker.onDocumentChanged = { [weak self] url in self?.history.record(url) }
        menuBar = MenuBarController()
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onReloadMenus = { [weak self] in self?.context.refreshMenuIndex() }
        menuBar.onOpenAccessibilitySettings = { Self.openAccessibilitySettings() }

        tap = EventTap(
            handler: { [weak self] keyCode, flags in
                self?.handleKey(keyCode: keyCode, flags: flags) ?? false
            },
            onInterrupted: { [weak self] in self?.abandonEverything() },
            onSecureInputChanged: { [weak self] _ in self?.updateStatus() }
        )

        observeFrontmostApplication()
        xcodeIsFrontmost = context.isFrontmost
        requestAccessibilityThenStart()
    }

    // MARK: - the keystroke path

    private func handleKey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard xcodeIsFrontmost else { return false }
        guard let event = EventBridge.keyEvent(keyCode: keyCode, flags: flags) else { return false }

        // A picker owns the keyboard while it is open. Everything is swallowed, including
        // keys it has no use for, or half of them would land in the editor behind it.
        if activePicker != nil { return handlePickerKey(event) }

        switch session.press(event) {
        case .passThrough:
            return false
        case .awaiting(let panel):
            whichKey.present(panel)
        case .fired(let commandID):
            whichKey.dismiss()
            // Posting a synthetic event from inside the tap callback would re-enter our own
            // tap before it has returned. Run on the next turn of the run loop instead.
            DispatchQueue.main.async { [weak self] in self?.run(commandID) }
        case .cancelled:
            whichKey.dismiss()
        }
        return true
    }

    private func handlePickerKey(_ event: KeyEvent) -> Bool {
        guard var current = activePicker else { return false }
        let outcome = current.press(event)
        activePicker = current
        switch outcome {
        case .updated:
            picker.update(current)
        case .ignored:
            break
        case .cancelled:
            closePicker()
        case .chosen(let item):
            closePicker()
            DispatchQueue.main.async { [weak self] in self?.choose(item) }
        }
        return true
    }

    // MARK: - running things

    private func run(_ commandID: String) {
        guard let command = registry.command(id: commandID) else {
            log.error("no command registered for \(commandID, privacy: .public)")
            return
        }
        switch executor.run(command) {
        case .opensPicker(let kind):
            openPicker(kind)
        case .posted(let key):
            log.debug("\(command.id, privacy: .public) via \(key.display, privacy: .public)")
        case .pressed(let path):
            log.debug("\(command.id, privacy: .public) via menu \(path.joined(separator: " > "), privacy: .public)")
        case .transformed(let n):
            log.debug("\(command.id, privacy: .public) rewrote \(n) characters")
        case .handledInternally:
            break
        case .unavailable(let why):
            log.notice("\(command.id, privacy: .public): \(why, privacy: .public)")
            NSSound.beep()
        }
    }

    /// What a chosen picker row does depends on which picker it came from. Rows carry an id
    /// that says: a command id, or a menu path, or a file URL.
    private func choose(_ item: PickerItem) {
        if item.id.hasPrefix("menu:") {
            let path = String(item.id.dropFirst(5)).components(separatedBy: "\u{1}")
            guard let entry = context.menuItem(at: path) else {
                log.notice("menu item vanished: \(path.joined(separator: " > "), privacy: .public)")
                NSSound.beep()
                return
            }
            if let shortcut = entry.shortcut {
                _ = executor.run(Command(id: item.id, title: item.title, action: .shortcut(shortcut)))
            } else {
                context.press(entry)
            }
        } else if item.id.hasPrefix("file:") {
            let path = String(item.id.dropFirst(5))
            // Record the choice *before* opening, so ranking improves even if the open
            // fails. This call is the one that makes frecency real rather than decorative.
            fileIndex.note(path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            run(item.id)
        }
    }

    // MARK: - pickers

    private func openPicker(_ kind: PickerKind) {
        let items: [PickerItem]
        switch kind {
        case .commands:      items = commandItems()
        case .destinations:  items = menuItems(under: ["Product", "Destination"])
        case .schemes:       items = menuItems(under: ["Product", "Scheme"])
        case .themes:        items = menuItems(under: ["Editor", "Theme"])
        case .syntaxColoring: items = menuItems(under: ["Editor", "Syntax Coloring"])
        case .recentProjects: items = menuItems(under: ["File", "Open Recent"])
        case .files:         items = fileItems()
        case .buffers:       items = history.items
        case .menuSlice:     items = commandItems()
        }
        guard !items.isEmpty else {
            log.notice("picker \(kind.rawValue, privacy: .public) has nothing to show")
            NSSound.beep()
            return
        }
        log.notice("picker \(kind.rawValue, privacy: .public) opened with \(items.count) rows")
        var s = PickerSession(title: kind.title, items: items)
        s.pageSize = 10
        activePicker = s
        picker.present(s)
    }

    private func closePicker() {
        activePicker = nil
        picker.dismiss()
    }

    /// Every command we know: ours, plus every menu item Xcode currently offers. The
    /// registry's own commands come first so `build` finds our binding rather than one of
    /// the several menu items containing the word.
    private func commandItems() -> [PickerItem] {
        var items = registry.all.map { command -> PickerItem in
            let binding = session.keymap.binding(for: command.id)
                .map { ([session.leader] + $0).map(\.display).joined(separator: " ") }
            return PickerItem(id: command.id, title: command.searchText, detail: binding)
        }
        let known = Set(registry.all.compactMap { $0.menuPath?.joined(separator: " > ") })
        for entry in context.allMenuItems() {
            let path = entry.path.joined(separator: " > ")
            guard !known.contains(path) else { continue }
            items.append(PickerItem(id: "menu:" + entry.path.joined(separator: "\u{1}"),
                                    title: path,
                                    detail: entry.shortcut?.display,
                                    isEnabled: entry.isEnabled))
        }
        return items
    }

    private func menuItems(under prefix: [String]) -> [PickerItem] {
        context.menuItems(under: prefix).map { entry in
            PickerItem(id: "menu:" + entry.path.joined(separator: "\u{1}"),
                       title: entry.path.last ?? "",
                       detail: entry.shortcut?.display,
                       isEnabled: entry.isEnabled)
        }
    }

    private func fileItems() -> [PickerItem] {
        fileIndex.refreshIfNeeded(around: context.documentURL())
        return fileIndex.items
    }

    private func runCompanionCommand(_ id: String) {
        switch id {
        case "quit": NSApp.terminate(nil)
        case "reloadMenus":
            context.refreshMenuIndex()
            fileIndex.invalidate()
        default: log.error("unknown companion command \(id, privacy: .public)")
        }
    }

    /// Every way a sequence or a picker can be abandoned ends here.
    private func abandonEverything() {
        if session.abandon() != nil { whichKey.dismiss() }
        if activePicker != nil { closePicker() }
    }

    // MARK: - permission and lifecycle

    private func requestAccessibilityThenStart() {
        hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility { start(); return }
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        updateStatus()

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
        log.notice("layout: \(KeyboardLayout.currentLayoutName(), privacy: .public), \(self.registry.count) commands")
        if context.isRunning { context.refreshMenuIndex() }
        tracker.start()
        updateStatus()
    }

    private func observeFrontmostApplication() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                let nowFrontmost = bundleID == "com.apple.dt.Xcode"
                if self.xcodeIsFrontmost && !nowFrontmost { self.abandonEverything() }
                self.xcodeIsFrontmost = nowFrontmost
                if nowFrontmost && self.hasAccessibility { self.context.refreshMenuIndex() }
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        let status = CompanionStatus.derive(hasAccessibility: hasAccessibility,
                                            secureInputActive: tap.secureInputActive,
                                            xcodeFrontmost: xcodeIsFrontmost)
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
