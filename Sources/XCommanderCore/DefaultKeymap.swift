import Foundation

/// The keymap the app ships with, and the registry behind it.
///
/// **Mnemonics follow Doom Emacs** wherever Doom has an equivalent, because muscle memory
/// transferring is the entire point of the product. The one deliberate deviation is
/// `SPC m` for build/run/test: Doom has nothing worth copying there (`SPC p c` is
/// project-compile), and in Xcode this is the most-used group in the product, so it earns
/// a short home. `m` is for "make".
///
/// Commands name the **action behind a menu item** (`MenuRef`), never its title and never a
/// hardcoded shortcut. A title is Apple's to rename — Xcode 27 renamed four of the items
/// bound here — and Xcode reports shortcuts as characters in the user's keyboard layout, so
/// a hardcoded table would be wrong on any layout but the author's. Every identifier below
/// resolves against `Fixtures/Xcode-27A266.json`, and a test fails if one stops.
public enum DefaultKeymap {

    /// **`⌥Return`, and the reason is a defect `⇧Space` had.**
    ///
    /// A leader that is also a text-producing key is swallowed while Xcode is frontmost, so
    /// a Shift held a beat too long across a word break armed the sequence — and since the
    /// session has no way to know the space was an accident, the *next word you typed* was
    /// read as a command. `wo…` closed your other editor panes; `ma…` started a build. Nine
    /// of eighteen ordinary English words reached something; see `NEXT-ANSWERS.md`.
    ///
    /// `⌥Return` cannot be produced as a character in the editor, so the failure is not
    /// mitigated but structurally absent. The sequence timeout below is separate hygiene: it
    /// does not help here, because a mis-typed leader and the next letter are milliseconds
    /// apart.
    public static let leader = KeyEvent(.return, [.option])

    /// The shipped keymap as data, for `ConfigResolver` to layer a user's file over.
    ///
    /// The same two tables `build()` uses. Exposed rather than duplicated, so a config file
    /// can never be merged against a keymap that differs from the one the app ships.
    public static var blueprint: KeymapBlueprint {
        KeymapBlueprint(bindings: bindings.map { (sequence: $0.0, commandID: $0.1) },
                        groupTitles: groupTitles)
    }

    public static func build() -> (registry: CommandRegistry, keymap: Keymap) {
        var registry = CommandRegistry()
        registry.register(contentsOf: commands)

        var keymap = Keymap()
        for (sequence, id) in bindings {
            // A conflict here is a programming error in this file. The test suite builds
            // this keymap, so it surfaces there rather than at launch.
            try! keymap.bind(sequence, to: id, groupTitles: groupTitles)
        }
        return (registry, keymap)
    }

    static let groupTitles: [[KeyEvent]: String] = [
        [KeyEvent("b")]: "buffers",
        [KeyEvent("c")]: "code",
        [KeyEvent("d")]: "debug",
        [KeyEvent("f")]: "files",
        [KeyEvent("g")]: "git",
        [KeyEvent("h")]: "help",
        [KeyEvent("i")]: "inspector",
        [KeyEvent("m")]: "make",
        [KeyEvent("n")]: "navigator",
        [KeyEvent("p")]: "project",
        [KeyEvent("q")]: "quit",
        [KeyEvent("s")]: "search",
        [KeyEvent("t")]: "toggles",
        [KeyEvent("T")]: "ui",
        [KeyEvent("w")]: "windows",
        // macOS window management, one level down: it is a different object from an editor
        // pane, and keeping it out of the way frees w H/J/K/L for sending a buffer.
        [KeyEvent("w"), KeyEvent("W")]: "os window",
        [KeyEvent("x")]: "text",
    ]

    // MARK: - commands

    static let commands: [Command] = navigatorCommands + areaCommands + [
        // pickers
        .picker("picker.commands", "commands", .commands, searchText: "command palette"),
        .picker("picker.files", "find file", .files, searchText: "find file in project"),
        .picker("picker.buffers", "switch editor", .buffers, searchText: "switch open editor"),
        .picker("picker.destinations", "destination", .destinations, searchText: "run destination simulator"),
        .picker("picker.schemes", "scheme", .schemes),
        .picker("picker.themes", "theme", .themes),
        .picker("picker.syntax", "syntax coloring", .syntaxColoring),
        .picker("picker.recent", "recent projects", .recentProjects),
        .picker("picker.search", "search project", .projectSearch,
                searchText: "search project with ripgrep"),
        .picker("picker.docSymbols", "symbols in file", .documentSymbols,
                searchText: "symbols in this file"),
        .picker("picker.projectSymbols", "project symbols", .projectSymbols,
                searchText: "symbols across the project"),

        // make — build, run, test
        .menu("make.build", "build", MenuRef("buildActiveRunContext:")),
        .menu("make.run", "run", MenuRef("runActiveRunContext:")),
        .menu("make.test", "test", MenuRef("testActiveRunContext:")),
        .menu("make.clean", "clean", MenuRef("cleanActiveRunContext:")),
        .menu("make.stop", "stop", MenuRef("cancelCurrentExecution:")),
        .menu("make.analyze", "analyze", MenuRef("analyzeActiveRunContext:")),
        .menu("make.profile", "profile", MenuRef("profileActiveScheme:")),
        .menu("make.docs", "build documentation", MenuRef("buildDocumentationForActiveRunContext:")),
        .menu("make.testAgain", "test again", MenuRef("testAgain:")),
        .menu("make.runNoBuild", "run without building", MenuRef("runActiveRunContextWithoutBuilding:")),
        .menu("make.testNoBuild", "test without building", MenuRef("testActiveRunContextWithoutBuilding:")),
        .menu("make.clearResults", "clear test results", MenuRef("clearTestResults:")),

        // files
        .menu("file.openQuickly", "open quickly", MenuRef("openQuickly:")),
        .menu("file.save", "save", MenuRef("ide_saveDocument:")),
        .menu("file.saveAll", "save all", MenuRef("saveAllEditorDocuments:")),
        .menu("file.new", "new file", MenuRef("newFileFromTemplate:")),
        // The title carries the open file's name — `Close “main.swift”` — so this names the
        // title carries the open file's name; the action behind it does not move.
        .menu("file.close", "close document", MenuRef("topLevelEditorContext_closeDocument:")),
        .menu("file.revealInFinder", "reveal in finder", MenuRef("showInFinder:")),

        // buffers / tabs
        .menu("buffer.nextTab", "next tab", MenuRef("_showNextEditorTab:")),
        .menu("buffer.previousTab", "previous tab", MenuRef("_showPreviousEditorTab:")),
        .popup("buffer.newTab", "new tab", .addEditor("newTab:")),

        // code
        .menu("code.definition", "jump to definition", MenuRef("editorContext_jumpToDefinition:")),
        .menu("code.callers", "call hierarchy", MenuRef("showCallHierarchy:")),
        .menu("code.rename", "rename", MenuRef("renameRefactor:")),
        .menu("code.editAllInScope", "edit all in scope", MenuRef("toggleTokenizedEditing:")),
        .menu("code.fixAll", "fix all issues", MenuRef("fixAllIssues:")),
        .menu("code.formatFile", "format file", MenuRef("formatFile:")),
        .menu("code.formatSelection", "format selection", MenuRef("formatSelection:")),
        .menu("code.reindent", "re-indent", MenuRef("indentSelection:")),
        // Xcode 26 calls this "Toggle Comments"; it was "Comment Selection" when the keymap
        // was written, and the command sat dead until `⌥RET h c` reported it.
        .menu("code.comment", "toggle comments", MenuRef("toggleComments:")),
        .menu("code.addDocs", "add documentation", MenuRef("addDocumentation:")),
        .menu("code.moveLineUp", "move line up", MenuRef("moveCurrentLineUp:")),
        .menu("code.moveLineDown", "move line down", MenuRef("moveCurrentLineDown:")),
        .menu("code.extractFunction", "extract to function", MenuRef("extractFunction:")),
        .menu("code.extractVariable", "extract to variable", MenuRef("extractExpression:")),
        .menu("code.memberwiseInit", "generate memberwise init", MenuRef("generateMemberwiseInitializer:")),
        .menu("code.quickHelp", "quick help", MenuRef("showQuickHelp:")),
        // Xcode offers most navigation three ways — here, in a tab, or in the next pane —
        // which is the same "where should this land" idea Doom has, already built in.
        .menu("code.definitionInPane", "definition in next pane",
              MenuRef("editorContext_jumpToDefinitionWithShiftPlusAlternate:")),
        .menu("code.definitionInTab", "definition in a tab",
              MenuRef("editorContext_jumpToDefinitionWithAlternate:")),
        .menu("code.counterpart", "counterpart", MenuRef("jumpToNextCounterpart:")),
        .menu("code.counterpartInPane", "counterpart in next pane",
              MenuRef("jumpToNextCounterpartWithShiftPlusAlternate:")),

        // navigate
        .menu("nav.back", "back", MenuRef("topLevelEditorContext_goBackInHistoryByCommand:")),
        .menu("nav.forward", "forward", MenuRef("topLevelEditorContext_goForwardInHistoryByCommand:")),
        .menu("nav.nextIssue", "next issue", MenuRef("topLevelEditorContext_jumpToNextIssue:")),
        .menu("nav.previousIssue", "previous issue", MenuRef("topLevelEditorContext_jumpToPreviousIssue:")),

        // search
        .menu("search.find", "find", MenuRef("find:")),
        .menu("search.project", "find in project", MenuRef("findInWorkspace:")),
        .menu("search.replace", "find and replace", MenuRef("findAndReplace:")),
        .menu("search.next", "next match", MenuRef("findNext:")),
        .menu("search.previous", "previous match", MenuRef("findPrevious:")),
        .menu("search.selection", "use selection for find", MenuRef("useSelectionForFind:")),

        // git
        .menu("git.commit", "commit", MenuRef("commitCommand:")),
        .menu("git.push", "push", MenuRef("pushCommand:")),
        .menu("git.pull", "pull", MenuRef("updateCommand:")),
        .menu("git.fetch", "fetch", MenuRef("fetchChangesCommand:")),
        .menu("git.stageAll", "stage all", MenuRef("stageWorkingCopiesCommand:")),
        .menu("git.unstageAll", "unstage all", MenuRef("unstageWorkingCopiesCommand:")),
        .menu("git.stash", "stash", MenuRef("stashCommand:")),
        .menu("git.discard", "discard all changes", MenuRef("revertWorkingCopiesCommand:")),
        .menu("git.cherryPick", "cherry-pick", MenuRef("cherryPickCommand:")),

        // debug
        .menu("debug.pause", "pause", MenuRef("pauseOrContinue:")),
        .menu("debug.stepOver", "step over", MenuRef("stepOver:")),
        .menu("debug.stepInto", "step into", MenuRef("stepInto:")),
        .menu("debug.stepOut", "step out", MenuRef("stepOut:")),
        .menu("debug.continueToLine", "continue to line", MenuRef("continueToCurrentLine:")),
        .menu("debug.deactivateBreakpoints", "deactivate breakpoints", MenuRef("toggleBreakpoints:")),
        .menu("debug.detach", "detach", MenuRef("detach:")),

        // toggles
        // **These eight carry a path as well as an action, and they are the exception that
        // proves the rule.** Read once with the editor focused they report
        // `toggleMinimapShown:`; read again in another state they report `Show Minimap` —
        // the identifier flips with the toggle. So the path is written down for them, and
        // for nothing else.
        .menu("toggle.minimap", "minimap", MenuRef("toggleMinimapShown:", path: ["Editor", "Minimap"])),
        .menu("toggle.wrap", "wrap lines", MenuRef("toggleWrapLines:", path: ["Editor", "Wrap Lines"])),
        .menu("toggle.vim", "vim mode", MenuRef("toggleViMode:", path: ["Editor", "Vim Mode"])),
        .menu("toggle.invisibles", "invisibles", MenuRef("toggleInvisibleCharactersShown:", path: ["Editor", "Invisibles"])),
        .menu("toggle.lineNumbers", "relative line numbers", MenuRef("toggleLineNumbersStyle:", path: ["Editor", "Relative Line Numbers"])),
        .menu("toggle.authors", "authors", MenuRef("toggleAuthorsShown:", path: ["Editor", "Authors"])),
        .menu("toggle.coverage", "code coverage", MenuRef("toggleCodeCoverageShown:", path: ["Editor", "Code Coverage"])),
        .menu("toggle.scopeGuides", "scope guides", MenuRef("toggleScopeGuidesShown:", path: ["Editor", "Scope Guides"])),
        // A real toggle because `toggleNavigator:` is one action for both states: this
        // names one spelling and works in both directions. Worth having because the
        // cross-pane buffer list only exists while the tab bars do.
        .menu("toggle.tabBar", "editor tab bar", MenuRef("toggleShowEditorTabBar:")),

        // ui
        .menu("ui.fontIncrease", "font bigger", MenuRef("increaseFontSize:")),
        .menu("ui.fontDecrease", "font smaller", MenuRef("decreaseFontSize:")),
        .menu("ui.fontReset", "font reset", MenuRef("resetFontSize:")),

        // windows / panes — the directional moves, balance and zoom are ours, because
        // Xcode can only cycle between panes.
        .pane("pane.left", "focus left", .focus(.left), searchText: "focus the pane to the left"),
        .pane("pane.down", "focus down", .focus(.down), searchText: "focus the pane below"),
        .pane("pane.up", "focus up", .focus(.up), searchText: "focus the pane above"),
        .pane("pane.right", "focus right", .focus(.right), searchText: "focus the pane to the right"),
        .pane("pane.balance", "balance panes", .balance, searchText: "make the panes equal"),
        .pane("pane.zoom", "zoom pane", .zoom, searchText: "maximise this pane, again to restore"),
        .pane("pane.grow", "grow pane", .grow),
        .pane("pane.shrink", "shrink pane", .shrink),
        // Neither of these exists in Xcode. Both are synthesised; see `PaneController`.
        .pane("pane.swap", "swap panes", .swap,
              searchText: "exchange this pane's file with the next"),
        .pane("pane.sendLeft", "send left", .send(.left),
              searchText: "send this file to the pane on the left"),
        .pane("pane.sendDown", "send down", .send(.down),
              searchText: "send this file to the pane below"),
        .pane("pane.sendUp", "send up", .send(.up),
              searchText: "send this file to the pane above"),
        .pane("pane.sendRight", "send right", .send(.right),
              searchText: "send this file to the pane on the right"),

        .popup("window.paneRight", "pane on right", .addEditor("newEditorAreaSplitOnRight:")),
        .popup("window.paneBelow", "pane below", .addEditor("newEditorAreaSplitBelow:")),
        .menu("window.closePane", "close pane", MenuRef("_closeActiveEditor:")),
        .menu("window.nextPane", "next pane", MenuRef("moveKeyboardFocusToNextEditor:")),
        .menu("window.previousPane", "previous pane", MenuRef("moveKeyboardFocusToPreviousEditor:")),
        .menu("window.nextArea", "next area", MenuRef("moveKeyboardFocusToNextArea:")),
        .menu("window.editorOnly", "editor only", MenuRef("_showEditorOnly:")),
        .menu("window.closeOthers", "close other panes", MenuRef("closeOtherEditors:")),
        .menu("window.openInNext", "open in next pane", MenuRef("openInAdjacentEditorWithShiftPlusAlternate:")),
        .menu("window.openInTab", "open in a tab", MenuRef("openInAdjacentEditorWithAlternate:")),
        .menu("window.choosePane", "choose pane…", MenuRef("moveFocusToEditor:")),
        .menu("window.tabToWindow", "move tab to new window", MenuRef("moveTabToNewWindow:")),
        .menu("window.mergeAll", "merge all windows", MenuRef("mergeAllWindows:")),
        .menu("window.tileLeft", "tile left", MenuRef("_zoomLeft:")),
        .menu("window.tileRight", "tile right", MenuRef("_zoomRight:")),
        .menu("window.tileFull", "fill screen", MenuRef("_zoomFill:")),
        .menu("window.previousSize", "previous size", MenuRef("_zoomUntile:")),
        .menu("window.toggleNavigator", "toggle navigator", MenuRef("toggleNavigator:")),
        .menu("window.toggleInspector", "toggle inspector", MenuRef("toggleInspectorArea:")),
        .menu("window.toggleDebugArea", "toggle debug area", MenuRef("toggleDebuggerVisibility:")),

        // navigator — the left-hand pane. Selecting one is an ordinary menu command, and
        // the menu item reveals the pane when it is hidden, so there is no special case.
        // Only focusing it needs Accessibility; see `NavigatorController`.
        .menu("navigator.filter", "filter navigator", MenuRef("filterInNavigator:")),

        // inspector — the right-hand pane. Entirely menu-driven; there is nothing in it
        // worth focusing, so it has no focus command. See `XcodeArea`.
        .menu("inspector.file", "file inspector", MenuRef("showInspectorWithChoiceFromSender:", title: "File")),
        .menu("inspector.history", "history inspector", MenuRef("showInspectorWithChoiceFromSender:", title: "History")),
        .menu("inspector.quickHelp", "quick help inspector", MenuRef("showInspectorWithChoiceFromSender:", title: "Quick Help")),

        // debug area — the bottom pane. `Activate Console` already moves the keyboard into
        // the console, so only the variables list needs Accessibility.
        .menu("debug.console", "activate console", MenuRef("activateConsole:")),

        // help
        .menu("help.docs", "developer documentation", MenuRef("windowMenu_showDocumentation:", title: "Developer Documentation")),
        .menu("help.hig", "human interface guidelines", MenuRef("showHumanInterfaceGuidelines:")),
        .menu("help.swiftBook", "the swift book", MenuRef("showSwiftProgrammingLanguageBook:")),
        .menu("help.searchDocs", "search docs for selection", MenuRef("searchDocumentationForSelectedText:")),

        // quit
        .menu("quit.xcode", "quit xcode", MenuRef("terminate:")),
        Command(id: "quit.companion", title: "quit companion",
                searchText: "quit XCommander", action: .companion("quit")),
        Command(id: "companion.reload", title: "reload commands",
                searchText: "reload Xcode commands", action: .companion("reloadMenus")),
        Command(id: "companion.checkMenus", title: "check keymap",
                searchText: "check every binding still resolves against Xcode's menus",
                action: .companion("checkMenus")),

        // text transforms — the ones Xcode does not have
        .transform("text.align", TextTransform.align.title, .align,
                   searchText: "align selection on delimiter"),
        .transform("text.join", TextTransform.joinLines.title, .joinLines, searchText: "join lines"),
        .transform("text.sort", TextTransform.sortLines.title, .sortLines, searchText: "sort lines"),
        .transform("text.sortReversed", TextTransform.sortLinesReversed.title, .sortLinesReversed),
        .transform("text.dedupe", TextTransform.removeDuplicateLines.title, .removeDuplicateLines),
        .transform("text.reverse", TextTransform.reverseLines.title, .reverseLines),
        .transform("text.trim", TextTransform.trimTrailingWhitespace.title, .trimTrailingWhitespace),
        .transform("text.upper", TextTransform.upperCase.title, .upperCase),
        .transform("text.lower", TextTransform.lowerCase.title, .lowerCase),
        .transform("text.camel", TextTransform.camelCase.title, .camelCase),
        .transform("text.snake", TextTransform.snakeCase.title, .snakeCase),
    ]

    /// One command per navigator, from the single table in `XcodeNavigator`. Written this
    /// way rather than nine hand-typed lines so a new navigator cannot be added to the enum
    /// and then quietly forgotten here — the test asserts every case is reachable.
    static let navigatorCommands: [Command] = XcodeNavigator.allCases.map(\.command)

    /// One command per focusable area, from the single table in `XcodeArea`, for the same
    /// reason: a case added to the enum and forgotten here is caught by the test rather than
    /// by never working.
    static let areaCommands: [Command] = XcodeArea.allCases.map(\.command)

    // MARK: - bindings

    static let bindings: [([KeyEvent], String)] = [
        // Doom's own top-level keys, kept exactly.
        ([" "], "picker.files"),          // Doom's SPC SPC — find file in project
        ([":"], "picker.commands"),       // SPC :   — M-x
        ([","], "picker.buffers"),        // SPC ,   — switch buffer
        (["."], "file.openQuickly"),      // SPC .   — find file
        (["/"], "picker.search"),         // SPC /   — search project, ours

        // b — buffers
        (["b", "b"], "picker.buffers"),
        (["b", "n"], "buffer.nextTab"),
        (["b", "p"], "buffer.previousTab"),
        (["b", "t"], "buffer.newTab"),
        (["b", "d"], "file.close"),
        (["b", "s"], "file.save"),
        (["b", "S"], "file.saveAll"),

        // f — files
        (["f", "f"], "file.openQuickly"),
        (["f", "F"], "picker.files"),
        (["f", "s"], "file.save"),
        (["f", "S"], "file.saveAll"),
        (["f", "n"], "file.new"),
        (["f", "r"], "picker.recent"),
        (["f", "d"], "file.close"),
        (["f", "R"], "file.revealInFinder"),

        // p — project
        (["p", "f"], "picker.files"),
        (["p", "d"], "picker.destinations"),
        (["p", "s"], "picker.schemes"),
        (["p", "r"], "picker.recent"),
        (["p", "/"], "picker.search"),

        // m — make
        (["m", "m"], "make.build"),
        (["m", "r"], "make.run"),
        (["m", "t"], "make.test"),
        (["m", "c"], "make.clean"),
        (["m", "k"], "make.stop"),
        (["m", "a"], "make.analyze"),
        (["m", "p"], "make.profile"),
        (["m", "d"], "make.docs"),
        (["m", "T"], "make.testAgain"),
        (["m", "R"], "make.runNoBuild"),
        (["m", "N"], "make.testNoBuild"),
        (["m", "C"], "make.clearResults"),

        // c — code
        (["c", "d"], "code.definition"),
        (["c", "c"], "code.callers"),
        (["c", "r"], "code.rename"),
        (["c", "e"], "code.editAllInScope"),
        (["c", "x"], "code.fixAll"),
        (["c", "f"], "code.formatFile"),
        (["c", "F"], "code.formatSelection"),
        (["c", "i"], "code.reindent"),
        (["c", "k"], "code.addDocs"),
        (["c", "u"], "code.moveLineUp"),
        (["c", "j"], "code.moveLineDown"),
        (["c", "v"], "code.extractVariable"),
        (["c", "m"], "code.extractFunction"),
        (["c", "M"], "code.memberwiseInit"),
        (["c", "h"], "code.quickHelp"),
        (["c", "s"], "picker.docSymbols"),
        (["c", "S"], "picker.projectSymbols"),
        (["c", "D"], "code.definitionInPane"),
        (["c", "T"], "code.definitionInTab"),
        (["c", "a"], "code.counterpart"),
        (["c", "A"], "code.counterpartInPane"),
        (["c", "/"], "code.comment"),
        (["c", "o"], "nav.back"),
        (["c", "O"], "nav.forward"),
        (["c", "n"], "nav.nextIssue"),
        (["c", "p"], "nav.previousIssue"),

        // s — search
        (["s", "s"], "search.find"),
        (["s", "g"], "picker.search"),
        (["s", "p"], "search.project"),
        (["s", "r"], "search.replace"),
        (["s", "n"], "search.next"),
        (["s", "N"], "search.previous"),
        (["s", "e"], "search.selection"),

        // g — git
        (["g", "c"], "git.commit"),
        (["g", "p"], "git.push"),
        (["g", "F"], "git.pull"),
        (["g", "f"], "git.fetch"),
        (["g", "s"], "git.stageAll"),
        (["g", "u"], "git.unstageAll"),
        (["g", "z"], "git.stash"),
        (["g", "X"], "git.discard"),
        (["g", "y"], "git.cherryPick"),

        // d — debug
        (["d", "p"], "debug.pause"),
        (["d", "o"], "debug.stepOver"),
        (["d", "i"], "debug.stepInto"),
        (["d", "u"], "debug.stepOut"),
        (["d", "c"], "debug.continueToLine"),
        (["d", "b"], "debug.deactivateBreakpoints"),
        (["d", "d"], "debug.detach"),
        // the debug area itself, as opposed to the debugger
        (["d", "a"], "window.toggleDebugArea"),
        (["d", "C"], "debug.console"),
        (["d", "v"], "debug.focusVariables"),

        // t — toggles
        (["t", "m"], "toggle.minimap"),
        (["t", "w"], "toggle.wrap"),
        (["t", "v"], "toggle.vim"),
        (["t", "i"], "toggle.invisibles"),
        (["t", "l"], "toggle.lineNumbers"),
        (["t", "a"], "toggle.authors"),
        (["t", "c"], "toggle.coverage"),
        (["t", "g"], "toggle.scopeGuides"),
        (["t", "b"], "toggle.tabBar"),

        // T — ui
        (["T", "t"], "picker.themes"),
        (["T", "s"], "picker.syntax"),
        (["T", "+"], "ui.fontIncrease"),
        (["T", "-"], "ui.fontDecrease"),
        (["T", "0"], "ui.fontReset"),

        // w — windows and panes, laid out the way vim's ⌃w is
        (["w", "h"], "pane.left"),
        (["w", "j"], "pane.down"),
        (["w", "k"], "pane.up"),
        (["w", "l"], "pane.right"),
        (["w", "v"], "window.paneRight"),
        (["w", "s"], "window.paneBelow"),
        (["w", "d"], "window.closePane"),
        (["w", "q"], "window.closePane"),
        (["w", "o"], "window.closeOthers"),
        (["w", "w"], "window.nextPane"),
        (["w", "p"], "window.previousPane"),
        (["w", "="], "pane.balance"),
        (["w", "z"], "pane.zoom"),
        (["w", "."], "pane.grow"),
        (["w", ","], "pane.shrink"),
        (["w", "e"], "window.openInNext"),
        (["w", "E"], "window.openInTab"),
        (["w", "f"], "window.choosePane"),
        (["w", "a"], "window.nextArea"),
        (["w", "O"], "window.editorOnly"),

        // Exchanging and sending, which Xcode cannot do at all. `w x` is vim's ⌃w x; the
        // capitals are where vim puts ⌃w H/J/K/L, though ours sends the *buffer* rather
        // than moving the window — the split tree's shape is not writable from outside.
        (["w", "x"], "pane.swap"),
        (["w", "H"], "pane.sendLeft"),
        (["w", "J"], "pane.sendDown"),
        (["w", "K"], "pane.sendUp"),
        (["w", "L"], "pane.sendRight"),

        // macOS window management, one level down. These act on the *window*, not on an
        // editor pane, and they were occupying the letters vim reserves for moving windows.
        (["w", "W", "h"], "window.tileLeft"),
        (["w", "W", "l"], "window.tileRight"),
        (["w", "W", "f"], "window.tileFull"),
        (["w", "W", "r"], "window.previousSize"),
        (["w", "W", "t"], "window.tabToWindow"),
        (["w", "W", "m"], "window.mergeAll"),

        (["w", "n"], "window.toggleNavigator"),
        (["w", "i"], "window.toggleInspector"),
        (["w", "b"], "window.toggleDebugArea"),

        // x — text transforms
        (["x", "a"], "text.align"),
        (["x", "j"], "text.join"),
        (["x", "s"], "text.sort"),
        (["x", "S"], "text.sortReversed"),
        (["x", "d"], "text.dedupe"),
        (["x", "r"], "text.reverse"),
        (["x", "w"], "text.trim"),
        (["x", "u"], "text.upper"),
        (["x", "l"], "text.lower"),
        (["x", "c"], "text.camel"),
        (["x", "_"], "text.snake"),

        // n — the navigator, Xcode's left-hand pane
        (["n", "n"], "window.toggleNavigator"),
        (["n", "f"], "navigator.focus"),
        (["n", "p"], "navigator.project"),
        (["n", "g"], "navigator.sourceControl"),
        (["n", "b"], "navigator.bookmarks"),
        (["n", "s"], "navigator.find"),
        (["n", "i"], "navigator.issues"),
        (["n", "t"], "navigator.tests"),
        (["n", "d"], "navigator.debug"),
        (["n", "k"], "navigator.breakpoints"),
        (["n", "r"], "navigator.reports"),
        (["n", "/"], "navigator.filter"),

        // i — the inspector, Xcode's right-hand pane
        (["i", "i"], "window.toggleInspector"),
        (["i", "f"], "inspector.file"),
        (["i", "h"], "inspector.history"),
        (["i", "q"], "inspector.quickHelp"),

        // h — help
        (["h", "d"], "help.docs"),
        (["h", "h"], "help.hig"),
        (["h", "s"], "help.swiftBook"),
        (["h", "k"], "code.quickHelp"),
        (["h", "/"], "help.searchDocs"),
        (["h", "c"], "companion.checkMenus"),

        // q — quit
        (["q", "q"], "quit.companion"),
        (["q", "X"], "quit.xcode"),
        (["q", "r"], "companion.reload"),
    ]

    /// Every menu path the shipped keymap depends on.
    ///
    /// Read by `AppDelegate.reportUnresolvedMenuPaths()` at startup and on `⌥RET h c`. It sat
    /// here with **no caller at all** for a while, described as being "for a startup sanity
    /// check" that was never written — which is the failure it is meant to catch, in
    /// miniature: something plausible, tested, and wired to nothing.
    public static var menuRefs: [MenuRef] {
        commands.compactMap(\.menuRef)
    }

    /// Every shipped command backed by an Xcode menu item, for the audit — which wants to
    /// name the command a user would recognise, not just the action behind it.
    public static var menuCommands: [Command] {
        commands.filter { $0.menuRef != nil }
    }

    /// Every shipped command that lives in a toolbar popup instead. A snapshot of the menu
    /// bar cannot speak for these, so the audit counts them separately rather than quietly
    /// checking three fewer commands than the app ships.
    public static var popupCommands: [Command] {
        commands.filter { $0.popupRef != nil }
    }
}

extension KeyEvent: ExpressibleByStringLiteral {
    /// Lets the tables above read as `["m", "m"]`.
    ///
    /// The literal is **the character the user sees**, not a key plus a modifier: `"S"` is
    /// the character `S`, and `"/"` is the character `/`, however the user's layout
    /// produces them. See `KeyIdentity` for why Shift is not stored separately.
    public init(stringLiteral value: String) {
        precondition(value.count == 1, "a KeyEvent literal is one character: '\(value)'")
        if value == " " { self.init(.space, []); return }
        self.init(.character(value.first!), [])
    }
}
