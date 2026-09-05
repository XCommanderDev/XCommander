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
    private let settings = SettingsWindow()

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
        executor.panes = PaneController(context: context)
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

        tap = EventTap(
            handler: { [weak self] keyCode, flags in
                self?.handleKey(keyCode: keyCode, flags: flags) ?? false
            },
            onInterrupted: { [weak self] in self?.abandonEverything() },
            onSecureInputChanged: { [weak self] _ in self?.updateStatus() }
        )

        observeFrontmostApplication()
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
        } else if item.id.hasPrefix("symbol:") {
            let body = String(item.id.dropFirst(7))
            guard let separator = body.lastIndex(of: ":"),
                  let line = Int(body[body.index(after: separator)...]) else { return }
            let path = String(body[body.startIndex..<separator])
            fileIndex.note(path)
            ProjectSearch.jump(to: SearchMatch(path: path, line: line, text: "", start: 0, end: 0))
        } else if item.id.hasPrefix("match:") {
            // "match:<path>:<line>" — the path may contain colons, so take the line from
            // the end rather than splitting from the front.
            let body = String(item.id.dropFirst(6))
            guard let separator = body.lastIndex(of: ":"),
                  let line = Int(body[body.index(after: separator)...]) else { return }
            let path = String(body[body.startIndex..<separator])
            fileIndex.note(path)
            ProjectSearch.jump(to: SearchMatch(path: path, line: line, text: "", start: 0, end: 0))
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
        case .destinations:  items = menuItems(under: ["Product", "Destination"], icon: .destination)
        case .schemes:       items = menuItems(under: ["Product", "Scheme"])
        case .themes:        items = menuItems(under: ["Editor", "Theme"])
        case .syntaxColoring: items = menuItems(under: ["Editor", "Syntax Coloring"])
        case .recentProjects: items = menuItems(under: ["File", "Open Recent"])
        case .files:         items = fileItems()
        case .buffers:       items = history.items
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
            items.append(PickerItem(id: "menu:" + entry.path.joined(separator: "\u{1}"),
                                    title: path,
                                    detail: entry.shortcut?.display,
                                    isEnabled: entry.isEnabled,
                                    icon: .menuItem))
        }
        return items
    }

    private func menuItems(under prefix: [String], icon: RowIcon = .menuItem) -> [PickerItem] {
        context.menuItems(under: prefix).map { entry in
            PickerItem(id: "menu:" + entry.path.joined(separator: "\u{1}"),
                       title: entry.path.last ?? "",
                       detail: entry.shortcut?.display,
                       isEnabled: entry.isEnabled,
                       icon: icon)
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

    /// Push the stored settings into the parts that use them.
    private func applySettings() {
        whichKey.delay = SettingsWindow.overlayDelay
        menuBar.setEnabled(SettingsWindow.isEnabled)
        if !SettingsWindow.isEnabled { abandonEverything() }
        updateStatus()
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
