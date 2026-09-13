import AppKit
import ApplicationServices
import AutographeCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let context = AccessibilityXcodeContext()
    private var registry = CommandRegistry()
    /// Held so the session can be rebuilt when the leader changes — `KeymapSession.leader`
    /// is a `let`, deliberately, so switching it means a new session rather than a mutation
    /// that could land halfway through a sequence.
    private var keymap = Keymap()
    private var session: KeymapSession!
    private var executor: CommandExecutor!
    private var whichKey: OverlayController!
    private var picker: PickerOverlay!
    private var tap: EventTap!
    private var menuBar: MenuBarController!
    private let settings = SettingsWindow()
    /// The user's `config.toml`, if there is one. Owns the last-good rule.
    private var config: ConfigStore!

    /// Exactly one of these is active at a time. The keymap session drives the which-key
    /// panel; a picker, once open, takes every key until it is chosen or cancelled.
    private var activePicker: PickerSession?
    private var fileIndex = FileIndex()
    private var history = DocumentHistory()
    private var tracker: WindowTracker!
    private let search = ProjectSearch()
    private let symbolIndex = SymbolIndex()
    /// The root the open picker is searching, held so keystrokes can re-run the search.
    private var searchRoot: URL?
    /// The symbols behind an open symbol picker, filtered by our own matcher.
    private var symbolRows: [ProjectSymbol] = []

    /// Fires when an armed sequence has gone unresolved for `session.timeout`.
    private var sequenceTimer: Timer?

    private var xcodeIsFrontmost = false
    private var hasAccessibility = false
    private var accessibilityPollTimer: Timer?
    private let firstRun = FirstRunWindow()

    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let built = DefaultKeymap.build()
        registry = built.registry
        keymap = built.keymap
        session = KeymapSession(leader: SettingsWindow.leader.event,
                                keymap: built.keymap,
                                registry: built.registry)
        session.timeout = SettingsWindow.sequenceTimeout
        // The panel shows each command's live Xcode shortcut, which depends on the running
        // Xcode and the user's layout, so Core is handed a closure rather than a table.
        session.shortcutProvider = { [weak self] command in
            guard let self, let path = command.menuPath else { return nil }
            return MainActor.assumeIsolated { self.context.menuItem(at: path)?.shortcut?.display }
        }

        executor = CommandExecutor(context: context)
        executor.panes = PaneController(context: context)
        executor.areas = AreaController()
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
        menuBar.onToggleEnabled = { [weak self] in
            SettingsWindow.isEnabled.toggle()
            self?.applySettings()
        }
        menuBar.onShowSettings = { [weak self] in self?.settings.show() }
        settings.onChange = { [weak self] in self?.applySettings() }
        settings.checkKeymap = { [weak self] in self?.keymapCheckSummary() ?? "unavailable" }
        settings.rereadMenus = { [weak self] in
            self?.context.refreshMenuIndex()
            self?.fileIndex.invalidate()
        }
        settings.configSummary = { [weak self] in self?.configSummary() ?? "unavailable" }

        config = ConfigStore(registry: built.registry)
        config.projectRoot = { [weak self] in self?.projectRoot() }
        config.onChange = { [weak self] resolution in self?.apply(resolution) }

        tap = EventTap(
            handler: { [weak self] keyCode, flags in
                self?.handleKey(keyCode: keyCode, flags: flags) ?? false
            },
            onInterrupted: { [weak self] in self?.abandonEverything() },
            onSecureInputChanged: { [weak self] _ in self?.updateStatus() }
        )

        observeFrontmostApplication()
        // Last, because loading a file calls straight back into `apply(_:)`, which expects
        // the overlay and the menu bar to exist.
        config.start()
        menuBar.leaderDisplay = session.leader.display
        applySettings()
        xcodeIsFrontmost = context.isFrontmost
        requestAccessibilityThenStart()
    }

    // MARK: - the keystroke path

    private func handleKey(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        // Switched off from the menu: every key passes straight through, so the app is
        // inert rather than merely quiet.
        guard SettingsWindow.isEnabled else { return false }
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
            armSequenceTimeout()
        case .fired(let commandID):
            cancelSequenceTimeout()
            whichKey.dismiss()
            // Posting a synthetic event from inside the tap callback would re-enter our own
            // tap before it has returned. Run on the next turn of the run loop instead.
            DispatchQueue.main.async { [weak self] in self?.run(commandID) }
        case .cancelled:
            cancelSequenceTimeout()
            whichKey.dismiss()
        }
        return true
    }

    /// An armed sequence gives up on its own rather than waiting indefinitely for a key
    /// that is never coming. Rescheduled on every keypress, so the bound is on *idle* time
    /// and a slow deliberate sequence is never cut off mid-way.
    ///
    /// Scheduling this is not on the keystroke path in any meaningful sense — it happens
    /// after the tap callback has already decided to swallow the key.
    private func armSequenceTimeout() {
        cancelSequenceTimeout()
        let timer = Timer(timeInterval: session.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sequenceTimer = nil
                // `expireIfIdle` re-checks the clock, so a key that arrived between this
                // timer being scheduled and firing keeps the sequence alive.
                guard self.session.expireIfIdle() != nil else { return }
                self.whichKey.dismiss()
                self.log.notice("sequence timed out with nothing pressed")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        sequenceTimer = timer
    }

    private func cancelSequenceTimeout() {
        sequenceTimer?.invalidate()
        sequenceTimer = nil
    }

    private func handlePickerKey(_ event: KeyEvent) -> Bool {
        guard var current = activePicker else { return false }
        let outcome = current.press(event)
        activePicker = current
        switch outcome {
        case .updated:
            picker.update(current)
            if current.source == .dynamic {
                if symbolRows.isEmpty { runSearch(current.query) } else { applySymbolQuery(current.query) }
            }
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
        case .movedPane:
            break
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
        switch PickerTarget.parse(item.id) {
        case .menu(let path):
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
        case .tab(let pane, let index):
            // The row named coordinates in the live tree rather than a path, so a stale
            // row is a normal outcome — the user may have closed that tab since.
            if !context.selectTab(pane: pane, index: index) {
                log.notice("tab \(pane):\(index, privacy: .public) is no longer there")
                NSSound.beep()
            }
        case .file(let path, let line):
            // Record the choice *before* opening, so ranking improves even if the open
            // fails. This call is the one that makes frecency real rather than decorative.
            fileIndex.note(path)
            // Every picker that opens a file goes through here, and through `xed`. The file
            // picker used to call `NSWorkspace.open` instead, which routes to the app that
            // owns the extension — so choosing `notes.md` opened a Markdown previewer and
            // never reached Xcode at all.
            XcodeOpen.file(at: path, line: line)
        case .command(let id):
            run(id)
        }
    }

    // MARK: - pickers

    private func openPicker(_ kind: PickerKind) {
        let items: [PickerItem]
        switch kind {
        case .commands:      items = commandItems()
        case .destinations:  items = menuItems(under: ["Product", "Destination"], icon: .destination)
        case .schemes:       items = menuItems(under: ["Product", "Scheme"])
        case .themes:        items = menuItems(under: ["Editor", "Theme"])
        case .syntaxColoring: items = menuItems(under: ["Editor", "Syntax Coloring"])
        case .recentProjects: items = menuItems(under: ["File", "Open Recent"])
        case .files:         items = fileItems()
        case .buffers:       items = bufferItems()
        case .projectSearch:
            guard search.isAvailable else {
                log.notice("ripgrep is not installed; falling back to Xcode's find navigator")
                run("search.project")
                return
            }
            guard let root = projectRoot() else {
                log.notice("no project root to search")
                NSSound.beep()
                return
            }
            searchRoot = root
            // A search picker opens empty: there is nothing to show until a query exists.
            var session = PickerSession(title: "Search \(root.lastPathComponent)",
                                        items: [], source: .dynamic)
            session.pageSize = 10
            activePicker = session
            picker.present(session)
            return
        case .documentSymbols, .projectSymbols:
            openSymbolPicker(kind)
            return
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
        searchRoot = nil
        symbolRows = []
        search.cancel()
        picker.dismiss()
    }

    /// Symbols come from Xcode's own index, which is read off the main thread, so the
    /// picker opens immediately and fills in.
    private func openSymbolPicker(_ kind: PickerKind) {
        guard let root = projectRoot() else {
            log.notice("no project root for symbols")
            NSSound.beep()
            return
        }
        let currentFile = context.documentURL()?.path
        searchRoot = root
        var session = PickerSession(title: kind.title, items: [], source: .dynamic)
        session.pageSize = 10
        activePicker = session
        picker.present(session)

        symbolIndex.symbols(forProjectAt: root) { [weak self] result in
            guard let self, var open = self.activePicker else { return }
            if let reason = result.unavailable {
                open.replaceRows([PickerItem(id: "none", title: reason, isEnabled: false)])
                self.activePicker = open
                self.picker.update(open)
                return
            }
            var symbols = result.symbols
            if kind == .documentSymbols, let currentFile {
                symbols = symbols.filter { $0.path == currentFile }
                if symbols.isEmpty {
                    open.replaceRows([PickerItem(id: "none",
                                                 title: "no indexed symbols in this file",
                                                 isEnabled: false)])
                    self.activePicker = open
                    self.picker.update(open)
                    return
                }
            }
            self.symbolRows = symbols
            self.applySymbolQuery(open.query)
        }
    }

    /// Symbol pickers are dynamic, but their filtering is ours rather than an external
    /// command's, so the fuzzy matcher does the work here instead of in the session.
    private func applySymbolQuery(_ query: String) {
        guard var open = activePicker, !symbolRows.isEmpty else { return }
        let ranked = FuzzyMatcher.rank(symbolRows, query: query) { $0.name }
        open.replaceRows(ranked.prefix(300).map { entry in
            let symbol = entry.item
            return PickerItem(id: "symbol:\(symbol.path):\(symbol.line)",
                              title: symbol.name,
                              detail: symbol.location(relativeTo: searchRoot?.path),
                              icon: .symbol(symbol.kind))
        })
        activePicker = open
        picker.update(open)
    }

    /// Feed the query to ripgrep and put the hits back into the open picker.
    private func runSearch(_ query: String) {
        guard let root = searchRoot else { return }
        search.search(query, in: root) { [weak self] matches in
            guard let self, var session = self.activePicker, session.source == .dynamic else { return }
            session.replaceRows(matches.map { match in
                PickerItem(id: "match:\(match.path):\(match.line)",
                           // The line itself is the row, because that is what you are
                           // scanning for; the file and line sit on the right.
                           title: match.text.trimmingCharacters(in: .whitespaces),
                           detail: match.location(relativeTo: root.path),
                           icon: .searchHit)
            })
            self.activePicker = session
            self.picker.update(session)
        }
    }

    /// The project the open document belongs to, which is what we search.
    private func projectRoot() -> URL? {
        FileIndex.projectRoot(containing: context.documentURL() ?? history.current ?? URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// Every command we know: ours, plus every menu item Xcode currently offers. The
    /// registry's own commands come first so `build` finds our binding rather than one of
    /// the several menu items containing the word.
    private func commandItems() -> [PickerItem] {
        var items = registry.all.map { command -> PickerItem in
            let binding = session.keymap.binding(for: command.id)
                .map { ([session.leader] + $0).map(\.display).joined(separator: " ") }
            // A menu-backed command reads best as its path; one of ours reads best as its
            // name. Either way both strings are searchable, so "balance" finds "balance
            // panes" even though its description says "make the panes equal".
            let isMenu = command.menuPath != nil
            return PickerItem(id: command.id,
                              title: isMenu ? command.searchText : command.title,
                              detail: binding,
                              matchText: "\(command.title) \(command.searchText)",
                              icon: .forAction(command.action))
        }
        let known = Set(registry.all.compactMap { $0.menuPath?.joined(separator: " > ") })
        for entry in context.allMenuItems() {
            let path = entry.path.joined(separator: " > ")
            guard !known.contains(path) else { continue }
            items.append(PickerItem(id: PickerTarget.menuID(entry.path),
                                    title: path,
                                    detail: entry.shortcut?.display,
                                    isEnabled: entry.isEnabled,
                                    icon: .menuItem))
        }
        return items
    }

    private func menuItems(under prefix: [String], icon: RowIcon = .menuItem) -> [PickerItem] {
        context.menuItems(under: prefix).map { entry in
            PickerItem(id: PickerTarget.menuID(entry.path),
                       title: entry.path.last ?? "",
                       detail: entry.shortcut?.display,
                       isEnabled: entry.isEnabled,
                       icon: icon)
        }
    }

    /// The buffer list, from Xcode's own tab bars.
    ///
    /// This used to be `DocumentHistory` — a most-recently-visited list we maintained by
    /// watching which document had focus — because we believed Xcode exposed no tabs. It
    /// does: every pane carries an `AXTabGroup`. So the list is now the truth rather than a
    /// recollection, it spans every pane, and choosing a row presses the actual tab.
    ///
    /// **The fallback is not dead code, and it is not rare.** Xcode draws editor tab bars only when `View > Show Editor Tab Bar` is on, or
    /// when some pane holds more than one tab — and then it draws one in *every* pane. With
    /// Xcode's default setting and one file per pane there are no tab bars at all, so this
    /// returns empty far more often than "you have one file open".
    /// So on a default Xcode the history is still what answers most of the time — and it is
    /// also the only thing that remembers files you have closed. `⌥RET t b` turns the tab bar
    /// on, which is what makes the cross-pane list appear.
    private func bufferItems() -> [PickerItem] {
        let rows = EditorTabList.rows(context.openEditors())
        return rows.isEmpty ? history.items : rows
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
            config.load()
        case "checkMenus":
            context.refreshMenuIndex()
            reportUnresolvedMenuPaths()
        default: log.error("unknown companion command \(id, privacy: .public)")
        }
    }

    /// Resolve every menu path the shipped keymap names against the live menu bar and say
    /// which ones are missing.
    ///
    /// **This exists because a command bound to a path Xcode has renamed is silently dead.**
    /// It runs, `AXPress` finds nothing, the user gets a beep, and no test can see it — the
    /// suite asserts that a command is registered and bound, which it still is. Xcode renames
    /// menu items between versions, so this is the only thing that would ever notice.
    ///
    /// A diagnostic rather than an assertion, because Xcode's menus are context-dependent:
    /// with no source editor focused, whole submenus are absent and a miss means nothing.
    /// Read it with a `.swift` file open. `⌥RET h c` re-runs it; see it with
    /// `tools/xc.sh logs`.
    private func reportUnresolvedMenuPaths() {
        let paths = DefaultKeymap.menuPaths
        let missing = paths.filter { context.menuItem(at: $0) == nil }
        guard !missing.isEmpty else {
            log.notice("keymap check: all \(paths.count) menu paths resolve")
            return
        }
        log.notice("keymap check: \(missing.count) of \(paths.count) menu paths did not resolve")
        for path in missing {
            log.notice("  unresolved: \(path.joined(separator: " > "), privacy: .public)")
        }
    }

    /// Every way a sequence or a picker can be abandoned ends here.
    private func abandonEverything() {
        cancelSequenceTimeout()
        if session.abandon() != nil { whichKey.dismiss() }
        if activePicker != nil { closePicker() }
    }

    // MARK: - permission and lifecycle

    private func requestAccessibilityThenStart() {
        hasAccessibility = AXIsProcessTrusted()
        if hasAccessibility { start(); return }
        updateStatus()
        // Before either branch below, because a user who grants it from System Settings
        // without touching our window should still be picked up within the second.
        pollForAccessibility()

        // Say what we are about to ask for, and why, before macOS asks in its own words.
        // On every launch after the first, the prompt goes straight up: the explanation has
        // been given, and the menu's `Open Accessibility Settings…` is the way back.
        if FirstRunWindow.shouldShow {
            firstRun.onContinue = { Self.promptForAccessibility() }
            firstRun.show()
        } else {
            Self.promptForAccessibility()
        }
    }

    /// Prompts once per app identity — granted, refused or dismissed, it is spent. The constant
    /// `kAXTrustedCheckOptionPrompt` is imported as a mutable global, which Swift 6 will not let
    /// us touch, so use its documented value.
    private static func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func pollForAccessibility() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.hasAccessibility = true
                self.firstRun.close()
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
        if context.isRunning {
            context.refreshMenuIndex()
            reportUnresolvedMenuPaths()
        }
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

    /// Put a freshly loaded configuration into service.
    ///
    /// The same move the leader popup makes, with a bigger payload: abandon anything in
    /// flight first, because a sequence armed under the old keymap has no meaning under the
    /// new one and finishing it would run whatever now sits at those keys.
    private func apply(_ resolution: ConfigResolution) {
        guard let replacement = resolution.keymap else { return }
        abandonEverything()
        keymap = replacement
        applySettings()
    }

    /// Push the stored settings into the parts that use them.
    ///
    /// **The file wins where it speaks.** A value the config file sets is not a preference
    /// any more, so the settings window's copy of it is ignored rather than fought with.
    /// Where the file is silent, the window is in charge.
    private func applySettings() {
        whichKey.delay = config?.current.overlayDelay ?? SettingsWindow.overlayDelay
        session.timeout = config?.current.sequenceTimeout ?? SettingsWindow.sequenceTimeout
        menuBar.setEnabled(SettingsWindow.isEnabled)

        // Changing the leader mid-sequence would leave the old one armed with no way to
        // finish it, so abandon first and rebuild around the new key.
        let chosen = (config?.current.leader ?? SettingsWindow.leader).event
        if session.leader != chosen || session.keymap != keymap {
            abandonEverything()
            var replacement = KeymapSession(leader: chosen, keymap: keymap, registry: registry)
            replacement.timeout = session.timeout
            replacement.shortcutProvider = session.shortcutProvider
            session = replacement
            menuBar.leaderDisplay = chosen.display
            log.notice("leader is now \(chosen.display, privacy: .public)")
        }

        if !SettingsWindow.isEnabled { abandonEverything() }
        updateStatus()
    }

    /// What the configuration file had to say, as one line for the settings window.
    ///
    /// A config error belongs where a person will look for it. The system log is not that
    /// place — it is where this used to report, and nobody ever found it.
    private func configSummary() -> String {
        config.load()
        if let summary = config.current.summary ?? config.diagnostics.forDisplay.first.map(\.description) {
            return summary
        }
        let file = ConfigStore.globalFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            return "No config file. Create ~/.config/autographe/config.toml to customise the keymap."
        }
        return "\(file.lastPathComponent) loaded, no problems."
    }

    /// The keymap check as one line, for the settings window. The log gets the detail.
    private func keymapCheckSummary() -> String {
        context.refreshMenuIndex()
        let paths = DefaultKeymap.menuPaths
        let missing = paths.filter { context.menuItem(at: $0) == nil }
        reportUnresolvedMenuPaths()
        guard !missing.isEmpty else { return "All \(paths.count) bindings resolve." }
        let names = missing.prefix(2).map { $0.joined(separator: " › ") }.joined(separator: ", ")
        let more = missing.count > 2 ? " and \(missing.count - 2) more" : ""
        return "\(missing.count) of \(paths.count) unresolved: \(names)\(more). "
            + "Open a Swift file and try again — Xcode's menus are context-dependent."
    }

    private func updateStatus() {
        let status = CompanionStatus.derive(hasAccessibility: hasAccessibility,
                                            secureInputActive: tap.secureInputActive,
                                            xcodeFrontmost: xcodeIsFrontmost,
                                            enabled: SettingsWindow.isEnabled)
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
