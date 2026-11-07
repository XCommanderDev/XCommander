import AppKit
import ApplicationServices
import AutographeCore
import XcodeMenus
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
    private let previewLoader = PreviewLoader()
    /// The style the open picker previews in, so every selection change knows what to ask for.
    private var previewStyle: PreviewStyle = .none
    /// Which picker is open, so a window resize can ask the pane question again.
    private var activePickerKind: PickerKind?
    private let snapshots = SnapshotStore()
    /// Everything this app has ever seen the running Xcode offer, folded together across
    /// sessions. One scan is one context; the union is the menu. Nil until the first scan,
    /// and while it is nil nothing is hidden — an app that has not looked yet must not
    /// conclude a command is missing.
    private var knownMenu: MenuCatalogue?
    /// Window assumptions already asked about this session, as `build:assumption`. Checking
    /// one walks the whole window, so it is done once per build, after a failure, and never
    /// on the keystroke path of a command that works.
    private var settledAssumptions: Set<String> = []
    private var fileIndex = FileIndex()
    private var history = DocumentHistory()
    private var tracker: WindowTracker!
    private let search = ProjectSearch()
    private let symbolIndex = SymbolIndex()
    /// The root the open picker is searching, held so keystrokes can re-run the search.
    private var searchRoot: URL?
    /// The symbols behind an open symbol picker, filtered by our own matcher.
    private var symbolRows: [ProjectSymbol] = []
    /// The hits behind the open search picker's rows, by row id.
    ///
    /// A row's id carries the file and the line, which is all `choose` needs to open it. The
    /// preview needs one thing more — *where in the line* the hit is — so the matches are kept
    /// beside the rows rather than encoded into the id, which would change a format four other
    /// things parse.
    private var searchMatches: [String: SearchMatch] = [:]

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
        session = makeSession(leader: SettingsWindow.leader.event, keymap: built.keymap)

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
            // Decide the pane question again *before* repositioning, so the panel is placed at
            // the width it is about to have rather than the one it had.
            self?.reviewPreviewWidth()
            self?.picker.followWindow()
        }
        tracker.onDocumentChanged = { [weak self] url in self?.history.record(url) }
        menuBar = MenuBarController()
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.onReloadMenus = { [weak self] in self?.refreshMenus() }
        menuBar.onOpenAccessibilitySettings = { Self.openAccessibilitySettings() }
        menuBar.onToggleEnabled = { [weak self] in
            SettingsWindow.isEnabled.toggle()
            self?.applySettings()
        }
        menuBar.onShowSettings = { [weak self] in self?.settings.show() }
        settings.onChange = { [weak self] in self?.applySettings() }
        settings.checkKeymap = { [weak self] in self?.keymapCheckSummary() ?? "unavailable" }
        settings.rereadMenus = { [weak self] in
            self?.refreshMenus()
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
            // `.updated` covers typing and arrow keys alike, so one hook here serves every
            // way the selection can move.
            refreshPreview()
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
            explainWindowFailure(of: command)
        }
    }

    /// What a chosen picker row does depends on which picker it came from. Rows carry an id
    /// that says: a command id, or a menu path, or a file URL.
    private func choose(_ item: PickerItem) {
        switch PickerTarget.parse(item.id) {
        case .menu(let path):
            // The row was built from the live tree a moment ago, so a path is the right key
            // here — and the only one that can tell 102 run destinations apart.
            guard let entry = context.menuItem(for: .pathOnly(path)) else {
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

    /// How tall the pane is for a picker, and whether it has one at all.
    ///
    /// Decided here, once, before the panel is shown — the panel never resizes while it is
    /// open, so this is the only moment the question is asked.
    private static let previewPaneWidth: CGFloat = 620

    private func previewWidth(for kind: PickerKind) -> CGFloat {
        guard kind.previewStyle != .none else { return 0 }
        // Resolved, because `FileIndex` yields symlink-resolved paths: an unresolved root
        // would fail the containment test for every row and the pane would only ever say so.
        previewLoader.projectRoot = projectRoot()?.resolvingSymlinksInPath().path
        // Nothing to read means nothing to preview, and a pane that can only ever say so is
        // worse than no pane.
        guard previewLoader.projectRoot != nil else { return 0 }

        // Xcode's own window decides, falling back to the screen when it will not say — the
        // same fallback `PickerOverlay.reposition` uses to place the panel.
        let available = context.focusedWindowFrame()?.width
            ?? NSScreen.main?.visibleFrame.width ?? 0
        let panel = PickerOverlay.listWidth + Self.previewPaneWidth
        guard SettingsWindow.previewMode.showsPreview(inWindowOfWidth: Double(available),
                                                      panelWidth: Double(panel)) else { return 0 }
        return Self.previewPaneWidth
    }

    /// What a row wants previewed, including the one case `PreviewRequest` cannot answer.
    ///
    /// An editor tab is addressed by coordinates and carries only a file name, so it has no
    /// path to preview. Resolving that name through the file index is the only way to show
    /// one **without touching Xcode** — pressing the tab would render it perfectly and would
    /// also switch the user's editor under them, which is the thing this feature does not do.
    ///
    /// Returns nil after putting a reason in the pane, so the frame never collapses.
    private func previewRequest(for item: PickerItem) -> PreviewRequest? {
        if let request = PreviewRequest.of(item, style: previewStyle) {
            // Mark the searched-for text, which the row id does not carry.
            if case .text(let path, let line, _) = request,
               let match = searchMatches[item.id], match.end > match.start {
                return .text(path: path, focusLine: line,
                             highlight: match.start..<match.end)
            }
            return request
        }
        guard case .tab = PickerTarget.parse(item.id) else {
            picker.showPreview(.failure(.noOutline))
            return nil
        }
        let candidates = fileIndex.paths(named: item.title)
        switch candidates.count {
        case 1:
            return .outline(path: candidates[0])
        case 0:
            // Open but not in the project: a file from another package, or a header.
            picker.showPreview(.failure(.unreadable))
            return nil
        default:
            // Honest rather than arbitrary. Two `main.swift` in different targets are
            // indistinguishable from a tab title, and previewing the wrong one silently is
            // worse than saying there are two.
            picker.showPreview(.failure(.ambiguous(candidates: candidates.count)))
            return nil
        }
    }

    /// Xcode changed shape under an open picker: ask whether the pane still fits.
    ///
    /// The same rule that decided at open time, applied again — so narrowing Xcode drops the
    /// pane and the panel returns to exactly what it is without one, and widening it brings the
    /// pane back. `auto` is then honestly named: it tracks the window rather than sampling it
    /// once.
    private func reviewPreviewWidth() {
        guard picker.isVisible, let kind = activePickerKind else { return }
        guard picker.setPreviewWidth(previewWidth(for: kind)) else { return }
        // The pane it had was built for the old width, and its column budget just changed.
        refreshPreview()
    }

    /// Ask for whatever the current selection wants shown. Safe to call on every keystroke.
    private func refreshPreview() {
        guard previewStyle != .none, let item = activePicker?.selectedItem else {
            picker.showPreview(nil)
            return
        }
        guard let request = previewRequest(for: item) else { return }
        previewLoader.request(request, capacity: picker.previewCapacity,
                              columns: picker.previewColumns) { [weak self] result in
            self?.picker.showPreview(result)
        }
    }

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
            previewStyle = kind.previewStyle
            activePickerKind = kind
            picker.present(session, previewWidth: previewWidth(for: kind))
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
        previewStyle = kind.previewStyle
        activePickerKind = kind
        picker.present(s, previewWidth: previewWidth(for: kind))
        // The first row is selected the moment the panel appears, so its preview is asked for
        // then rather than on the first arrow key.
        refreshPreview()
    }

    private func closePicker() {
        activePicker = nil
        previewStyle = .none
        activePickerKind = nil
        searchMatches = [:]
        // Drop anything in flight, so a read that lands after the panel has gone does not
        // redraw a dismissed view.
        previewLoader.cancel()
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
        previewStyle = kind.previewStyle
        activePickerKind = kind
        picker.present(session, previewWidth: previewWidth(for: kind))

        symbolIndex.symbols(forProjectAt: root) { [weak self] result in
            guard let self, var open = self.activePicker else { return }
            if let reason = result.unavailable {
                open.replaceRows([PickerItem(id: "none", title: reason, isEnabled: false)])
                self.activePicker = open
                self.picker.update(open)
                self.refreshPreview()
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
                    self.refreshPreview()
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
        refreshPreview()
    }

    /// Feed the query to ripgrep and put the hits back into the open picker.
    private func runSearch(_ query: String) {
        guard let root = searchRoot else { return }
        search.search(query, in: root) { [weak self] matches in
            guard let self, var session = self.activePicker, session.source == .dynamic else { return }
            self.searchMatches = Dictionary(
                matches.map { ("match:\($0.path):\($0.line)", $0) },
                uniquingKeysWith: { first, _ in first })
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
            self.refreshPreview()
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
            // A menu-backed command reads as where it sits in *this* Xcode, asked live
            // rather than written down: the path a release moves is no longer in the source.
            let live = command.menuRef.flatMap { context.menuItem(for: $0)?.path }
            let title = live?.joined(separator: " > ") ?? command.title
            return PickerItem(id: command.id,
                              title: title,
                              detail: binding,
                              matchText: "\(command.title) \(title) \(command.searchText)",
                              icon: .forAction(command.action))
        }
        let known = Set(registry.all.compactMap {
            $0.menuRef.flatMap { context.menuItem(for: $0)?.path.joined(separator: " > ") }
        })
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
            refreshMenus()
            fileIndex.invalidate()
            config.load()
        case "checkMenus":
            refreshMenus()
            reportUnresolvedBindings()
        default: log.error("unknown companion command \(id, privacy: .public)")
        }
    }

    /// Resolve every menu item the shipped keymap names against the live menu bar and say
    /// which ones are missing.
    ///
    /// **This exists because a binding the running Xcode cannot resolve is silently dead.**
    /// It runs, `AXPress` finds nothing, the user gets a beep, and no test can see it — the
    /// suite resolves against a checked-in capture, not against the Xcode on this machine.
    /// A beta that drops an action is caught here first.
    ///
    /// A diagnostic rather than an assertion, because Xcode's menus are context-dependent:
    /// with no source editor focused, whole submenus are absent and a miss means nothing.
    /// Read it with a `.swift` file open. `⌥RET h c` re-runs it; see it with
    /// `tools/xc.sh logs`.
    private func reportUnresolvedBindings() {
        let commands = DefaultKeymap.menuCommands
        let missing = commands.filter { context.menuItem(for: $0.menuRef!) == nil }
        let release = context.release ?? XcodeRelease(version: "unknown", build: "unknown", major: 0)
        guard !missing.isEmpty else {
            log.notice("keymap check: all \(commands.count) bindings resolve on Xcode \(release.build, privacy: .public)")
            return
        }
        log.notice("keymap check: \(missing.count) of \(commands.count) bindings did not resolve on Xcode \(release.build, privacy: .public)")
        for command in missing {
            let ref = command.menuRef!
            let named = ref.isPathOnly ? (ref.path ?? []).joined(separator: " > ") : ref.identifier
            log.notice("  unresolved: \(command.title, privacy: .public) — \(named, privacy: .public)")
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
            refreshMenus()
            reportUnresolvedBindings()
        }
        tracker.follow()
        updateStatus()
    }

    /// Xcode coming forward and Xcode quitting are the two moments the process this app talks
    /// to can change: a relaunch after an update, a beta taking over from a release, or the
    /// first Xcode of the day after the app started at login. Both re-point the tracker; it
    /// does nothing when the process is the same one.
    private func observeFrontmostApplication() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self else { return }
                let nowFrontmost = bundleID == MenuScanner.bundleIdentifier
                if self.xcodeIsFrontmost && !nowFrontmost { self.abandonEverything() }
                self.xcodeIsFrontmost = nowFrontmost
                if nowFrontmost && self.hasAccessibility {
                    self.refreshMenus()
                    self.tracker.follow()
                }
                self.updateStatus()
            }
        }
        center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication)?.bundleIdentifier
            guard bundleID == MenuScanner.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.abandonEverything()
                self.tracker.follow()   // onto the other Xcode, if one is still open
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
            session = makeSession(leader: chosen, keymap: keymap)
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
        refreshMenus()
        let commands = DefaultKeymap.menuCommands
        let missing = commands.filter { context.menuItem(for: $0.menuRef!) == nil }
        reportUnresolvedBindings()
        let release = context.release ?? XcodeRelease(version: "unknown", build: "unknown", major: 0)
        guard !missing.isEmpty else {
            return "All \(commands.count) bindings resolve on Xcode \(release.version)."
        }
        let names = missing.prefix(2).map(\.title).joined(separator: ", ")
        let more = missing.count > 2 ? " and \(missing.count - 2) more" : ""
        return "\(missing.count) of \(commands.count) unresolved on Xcode \(release.version): \(names)\(more). "
            + "Open a Swift file and try again — Xcode's menus are context-dependent."
    }

    /// Build a keymap session wired to this app's view of Xcode.
    ///
    /// **Every session comes from here.** A session is rebuilt whenever the leader or the
    /// keymap changes, and the closures that connect it to Xcode are easy to forget at the
    /// second place that builds one — which is exactly what happened: the leader-change path
    /// copied the shortcut provider and dropped the availability provider, so after the first
    /// config reload the panel went back to printing keys this Xcode does not have. One
    /// function makes that mistake impossible rather than merely fixed.
    private func makeSession(leader: KeyEvent, keymap: Keymap) -> KeymapSession {
        var session = KeymapSession(leader: leader, keymap: keymap, registry: registry)
        session.timeout = config?.current.sequenceTimeout ?? SettingsWindow.sequenceTimeout
        // The panel shows each command's live Xcode shortcut, which depends on the running
        // Xcode and the user's layout, so Core is handed a closure rather than a table.
        session.shortcutProvider = { [weak self] command in
            guard let self, let ref = command.menuRef else { return nil }
            return MainActor.assumeIsolated { self.context.menuItem(for: ref)?.shortcut?.display }
        }
        // A key the panel prints and then cannot run is the worst thing this app can do,
        // so the panel is filtered by what the running Xcode actually offers.
        session.availabilityProvider = { [weak self] command in
            guard let self else { return true }
            return MainActor.assumeIsolated { self.isAvailable(command) }
        }
        return session
    }

    private func updateStatus() {
        let status = CompanionStatus.derive(hasAccessibility: hasAccessibility,
                                            secureInputActive: tap.secureInputActive,
                                            xcodeFrontmost: xcodeIsFrontmost,
                                            enabled: SettingsWindow.isEnabled,
                                            xcode: context.release)
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

// MARK: - what this Xcode offers

extension AppDelegate {

    /// Re-read Xcode's menus, and fold what we saw into what we already knew.
    ///
    /// Every refresh teaches the store something. Xcode's menus are context-dependent —
    /// `Debug >` fills in only during a session, whole submenus are absent with no editor
    /// focused — so no single scan can tell a deleted command from an inapplicable one. The
    /// union of many scans of the same build can, and that is what makes it safe to hide a
    /// key rather than leave it dead.
    func refreshMenus() {
        context.refreshMenuIndex()
        absorbScan()
    }

    /// Fold the latest scan into the store, and tell the user about the upgrade — once, and
    /// only when there is enough of the new build on record to be right about it.
    ///
    /// **The report waits for the build to settle.** The first scan of a new Xcode is one
    /// context like any other. Comparing it against the old build's accumulated menu — many
    /// sessions, many contexts — reports everything that first context happened not to show
    /// as removed by Apple: open Xcode 28 with the navigator focused and eight `Editor >`
    /// toggles "disappear". So the report fires on the scan that makes the build settled
    /// (`MenuSnapshot.isSettled`), which is usually the first one and never a misleading one.
    private func absorbScan() {
        guard let scan = context.lastScan, scan.release.major > 0 else { return }
        // Settled before this scan? Ask before recording, or the answer is always yes.
        let wasSettled = snapshots.load(build: scan.release.build)?.isSettled ?? false
        let accumulated: MenuSnapshot
        do {
            accumulated = try snapshots.record(scan)
        } catch {
            // Including a file from a newer version of this app, which `record` refuses to
            // overwrite. Either way the store cannot be trusted, so nothing is hidden.
            log.notice("could not record the menu snapshot (\(String(describing: error), privacy: .public)); nothing will be hidden")
            knownMenu = nil
            return
        }
        knownMenu = MenuCatalogue(accumulated)
        if !wasSettled, accumulated.isSettled,
           let previous = snapshots.previousBuild(before: scan.release.build) {
            reportXcodeChange(from: previous, to: accumulated)
        }
    }

    /// Whether the running Xcode offers a command at all.
    ///
    /// Two different questions, and conflating them is how a good idea becomes a bug:
    ///
    ///   * **Is it there right now?** If the live index has it, yes — nothing more to ask.
    ///   * **Does this Xcode have it at all?** Only the accumulated store can answer that,
    ///     and only once it has seen this build. Until then, everything is shown.
    ///
    /// A command that exists but is merely not applicable this second stays on the panel,
    /// greyed by Xcode's own `isEnabled` when it is pressed. Only a command this Xcode has
    /// never offered is hidden — and "never" needs a settled record of *this* build, not the
    /// last one scanned: with two Xcodes open, the store may know the other one better.
    func isAvailable(_ command: Command) -> Bool {
        guard let ref = command.menuRef else { return true }   // popups and ours always show
        if context.menuItem(for: ref) != nil { return true }
        guard let knownMenu, knownMenu.isSettled,
              knownMenu.release.build == context.release?.build else { return true }
        return knownMenu.isBound(ref)
    }

    /// Write the report and put one line in the menu bar. No sheet, no modal, no interruption.
    ///
    /// "Lost" means bound in the keymap the user actually has — the shipped one with their
    /// config layered on — not in the one the app ships. A command they unbound is not a key
    /// they lost, and a command their config bound is.
    private func reportXcodeChange(from old: MenuSnapshot, to new: MenuSnapshot) {
        let diff = CatalogueDiff.between(old, and: new)
        let before = MenuCatalogue(old), after = MenuCatalogue(new)
        let lost = registry.all.compactMap {
            command -> (command: String, title: String, identifier: String)? in
            guard let ref = command.menuRef, keymap.binding(for: command.id) != nil,
                  before.isBound(ref), !after.isBound(ref) else { return nil }
            return (command.id, command.title, ref.identifier)
        }
        // Whatever the new Xcode put on the leader's chord, that the old one had not.
        let leader = session.leader
        let wasOnLeader = Set(before.entries(withShortcut: leader).map(\.identifier))
        let shadowed = after.entries(withShortcut: leader).filter { !wasOnLeader.contains($0.identifier) }
        let report = ChangeReport(from: old.release, to: new.release, diff: diff, lostBindings: lost,
                                  leader: leader.display, newlyShadowed: shadowed)
        guard report.isWorthTelling else {
            log.notice("Xcode \(new.release.build, privacy: .public): nothing the user needs to know")
            return
        }
        do { try report.write() } catch {
            log.error("could not write the change report: \(String(describing: error), privacy: .public)")
            return
        }
        log.notice("Xcode changed: \(report.summaryLine, privacy: .public)")
        menuBar.announceXcodeChanges(report.summaryLine)
    }

    /// A command that needs Xcode's window just failed. Say why, if the window is the reason.
    ///
    /// Most failures are ordinary — no pane in that direction, no editor focused — and only a
    /// beep is right. A new Xcode that renamed its source editor or moved the Add Editor
    /// button looks identical from the keyboard: same beep, every time, forever. The
    /// difference is only visible by looking at the window, which is slow, so it is done
    /// here, after a failure, and at most once per assumption per build:
    ///
    ///   * if the assumption holds, the failure was ordinary, and it is not checked again;
    ///   * if it does not, a note goes into the change report and one line into the menu bar.
    ///
    /// Nothing is hidden on the strength of it — a missing editor may only mean no project is
    /// open — which is why the note says "may have changed" and asks for a report.
    private func explainWindowFailure(of command: Command) {
        let needed: XcodeAXSchema.Assumption
        switch command.action {
        case .pane: needed = .sourceEditor
        case .popupMenu: needed = .addEditorButton
        default: return
        }
        guard let release = context.release, release.major > 0 else { return }
        let key = "\(release.build):\(needed.rawValue)"
        guard !settledAssumptions.contains(key) else { return }

        let failed = context.checkWindowAssumptions().filter { $0.kind == needed && !$0.holds }
        settledAssumptions.insert(key)   // asked once per build either way
        guard !failed.isEmpty else { return }
        do {
            try ChangeReport.appendWindowNote(ChangeReport.windowNote(release: release, failed: failed))
        } catch {
            log.error("could not write the window note: \(String(describing: error), privacy: .public)")
            return
        }
        log.notice("\(command.id, privacy: .public) failed and Xcode \(release.build, privacy: .public)'s window does not match: \(needed.rawValue, privacy: .public)")
        menuBar.announceXcodeChanges("Xcode \(release.version) may have changed its window. See the report.")
    }
}
