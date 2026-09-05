import Foundation

/// The keymap the app ships with, and the registry behind it.
///
/// **Mnemonics follow Doom Emacs** wherever Doom has an equivalent, because muscle memory
/// transferring is the entire point of the product. The one deliberate deviation is
/// `SPC m` for build/run/test: Doom has nothing worth copying there (`SPC p c` is
/// project-compile), and in Xcode this is the most-used group in the product, so it earns
/// a short home. `m` is for "make".
///
/// Commands are named by **menu path**, never by a hardcoded shortcut. Xcode reports its
/// shortcuts as characters in the user's current keyboard layout, so a hardcoded table
/// would be wrong on any layout but the author's. Every path below was read off a real
/// Xcode 26.6 menu bar with a source editor focused, including the curly quotes in
/// `Format File with ‘swift-format’`.
public enum DefaultKeymap {

    public static let leader = KeyEvent(.space, [.shift])

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
        [KeyEvent("m")]: "make",
        [KeyEvent("p")]: "project",
        [KeyEvent("o")]: "open",
        [KeyEvent("q")]: "quit",
        [KeyEvent("s")]: "search",
        [KeyEvent("t")]: "toggles",
        [KeyEvent("T")]: "ui",
        [KeyEvent("w")]: "windows",
        [KeyEvent("x")]: "text",
    ]

    // MARK: - commands

    static let commands: [Command] = [
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
        .menu("make.build", "build", ["Product", "Build"]),
        .menu("make.run", "run", ["Product", "Run"]),
        .menu("make.test", "test", ["Product", "Test"]),
        .menu("make.clean", "clean", ["Product", "Clean Build Folder…"]),
        .menu("make.stop", "stop", ["Product", "Stop"]),
        .menu("make.analyze", "analyze", ["Product", "Analyze"]),
        .menu("make.profile", "profile", ["Product", "Profile"]),
        .menu("make.docs", "build documentation", ["Product", "Build Documentation"]),
        .menu("make.testAgain", "test again", ["Product", "Perform Action", "Test Again"]),
        .menu("make.runNoBuild", "run without building", ["Product", "Perform Action", "Run Without Building"]),
        .menu("make.testNoBuild", "test without building", ["Product", "Perform Action", "Test Without Building"]),
        .menu("make.clearResults", "clear test results", ["Product", "Clear Test Results"]),

        // files
        .menu("file.openQuickly", "open quickly", ["File", "Open Quickly…"]),
        .menu("file.save", "save", ["File", "Save"]),
        .menu("file.saveAll", "save all", ["File", "Save All"]),
        .menu("file.new", "new file", ["File", "New", "File from Template…"]),
        // The title carries the open file's name — `Close “main.swift”` — so this names the
        // stable prefix and relies on `menuItem(at:)`'s prefix fallback.
        .menu("file.close", "close document", ["File", "Close “"]),
        .menu("file.revealInFinder", "reveal in finder", ["File", "Show in Finder"]),

        // buffers / tabs
        .menu("buffer.nextTab", "next tab", ["Navigate", "Show Next Tab"]),
        .menu("buffer.previousTab", "previous tab", ["Navigate", "Show Previous Tab"]),
        .menu("buffer.newTab", "new tab", ["File", "New", "Tab"]),

        // code
        .menu("code.definition", "jump to definition", ["Navigate", "Jump to Definition"]),
        .menu("code.callers", "call hierarchy", ["Find", "Find Call Hierarchy"]),
        .menu("code.rename", "rename", ["Editor", "Refactor", "Rename…"]),
        .menu("code.editAllInScope", "edit all in scope", ["Editor", "Edit All in Scope"]),
        .menu("code.fixAll", "fix all issues", ["Editor", "Fix All Issues"]),
        .menu("code.formatFile", "format file", ["Editor", "Structure", "Format File with ‘swift-format’"]),
        .menu("code.formatSelection", "format selection", ["Editor", "Structure", "Format Selection with ‘swift-format’"]),
        .menu("code.reindent", "re-indent", ["Editor", "Structure", "Re-Indent"]),
        .menu("code.comment", "comment selection", ["Editor", "Structure", "Comment Selection"]),
        .menu("code.addDocs", "add documentation", ["Editor", "Structure", "Add Documentation"]),
        .menu("code.moveLineUp", "move line up", ["Editor", "Structure", "Move Line Up"]),
        .menu("code.moveLineDown", "move line down", ["Editor", "Structure", "Move Line Down"]),
        .menu("code.extractFunction", "extract to function", ["Editor", "Refactor", "Extract to Function"]),
        .menu("code.extractVariable", "extract to variable", ["Editor", "Refactor", "Extract to Variable"]),
        .menu("code.memberwiseInit", "generate memberwise init", ["Editor", "Refactor", "Generate Memberwise Initializer"]),
        .menu("code.quickHelp", "quick help", ["Help", "Show Quick Help for Selected Item"]),

        // navigate
        .menu("nav.back", "back", ["Navigate", "Show Previous Location in History"]),
        .menu("nav.forward", "forward", ["Navigate", "Show Next Location in History"]),
        .menu("nav.nextIssue", "next issue", ["Navigate", "Jump to Next Issue"]),
        .menu("nav.previousIssue", "previous issue", ["Navigate", "Jump to Previous Issue"]),

        // search
        .menu("search.find", "find", ["Find", "Find…"]),
        .menu("search.project", "find in project", ["Find", "Find in Package"]),
        .menu("search.replace", "find and replace", ["Find", "Find and Replace…"]),
        .menu("search.next", "next match", ["Find", "Find Next"]),
        .menu("search.previous", "previous match", ["Find", "Find Previous"]),
        .menu("search.selection", "use selection for find", ["Find", "Use Selection for Find"]),

        // git
        .menu("git.commit", "commit", ["Integrate", "Commit…"]),
        .menu("git.push", "push", ["Integrate", "Push…"]),
        .menu("git.pull", "pull", ["Integrate", "Pull…"]),
        .menu("git.fetch", "fetch", ["Integrate", "Fetch Changes"]),
        .menu("git.stageAll", "stage all", ["Integrate", "Stage All Changes"]),
        .menu("git.unstageAll", "unstage all", ["Integrate", "Unstage All Changes"]),
        .menu("git.stash", "stash", ["Integrate", "Stash Changes…"]),
        .menu("git.discard", "discard all changes", ["Integrate", "Discard All Changes…"]),
        .menu("git.cherryPick", "cherry-pick", ["Integrate", "Cherry-Pick…"]),

        // debug
        .menu("debug.pause", "pause", ["Debug", "Pause"]),
        .menu("debug.stepOver", "step over", ["Debug", "Step Over"]),
        .menu("debug.stepInto", "step into", ["Debug", "Step Into"]),
        .menu("debug.stepOut", "step out", ["Debug", "Step Out"]),
        .menu("debug.continueToLine", "continue to line", ["Debug", "Continue To Current Line"]),
        .menu("debug.deactivateBreakpoints", "deactivate breakpoints", ["Debug", "Deactivate Breakpoints"]),
        .menu("debug.detach", "detach", ["Debug", "Detach"]),

        // toggles
        .menu("toggle.minimap", "minimap", ["Editor", "Minimap"]),
        .menu("toggle.wrap", "wrap lines", ["Editor", "Wrap Lines"]),
        .menu("toggle.vim", "vim mode", ["Editor", "Vim Mode"]),
        .menu("toggle.invisibles", "invisibles", ["Editor", "Invisibles"]),
        .menu("toggle.lineNumbers", "relative line numbers", ["Editor", "Relative Line Numbers"]),
        .menu("toggle.authors", "authors", ["Editor", "Authors"]),
        .menu("toggle.coverage", "code coverage", ["Editor", "Code Coverage"]),
        .menu("toggle.scopeGuides", "scope guides", ["Editor", "Scope Guides"]),

        // ui
        .menu("ui.fontIncrease", "font bigger", ["Editor", "Font Size", "Increase"]),
        .menu("ui.fontDecrease", "font smaller", ["Editor", "Font Size", "Decrease"]),
        .menu("ui.fontReset", "font reset", ["Editor", "Font Size", "Reset"]),

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

        .menu("window.paneRight", "pane on right", ["File", "New", "Editor Pane On Right"]),
        .menu("window.paneBelow", "pane below", ["File", "New", "Editor Pane Below"]),
        .menu("window.closePane", "close pane", ["File", "Close Editor Pane"]),
        .menu("window.nextPane", "next pane", ["Navigate", "Move Focus to Next Editor Pane"]),
        .menu("window.previousPane", "previous pane", ["Navigate", "Move Focus to Previous Editor Pane"]),
        .menu("window.nextArea", "next area", ["Navigate", "Move Focus to Next Area"]),
        .menu("window.editorOnly", "editor only", ["Editor", "Show Editor Only"]),
        .menu("window.closeOthers", "close other panes", ["File", "Close Other Editor Panes"]),
        .menu("window.openInNext", "open in next pane", ["Navigate", "Open in Next Editor Pane"]),
        .menu("window.choosePane", "choose pane…", ["Navigate", "Move Focus to Editor Pane…"]),
        .menu("window.tabToWindow", "move tab to new window", ["Window", "Move Tab to New Window"]),
        .menu("window.mergeAll", "merge all windows", ["Window", "Merge All Windows"]),
        .menu("window.tileLeft", "tile left", ["Window", "Move & Resize", "Left"]),
        .menu("window.tileRight", "tile right", ["Window", "Move & Resize", "Right"]),
        .menu("window.tileFull", "fill screen", ["Window", "Move & Resize", "Halves"]),
        .menu("window.previousSize", "previous size", ["Window", "Move & Resize", "Return to Previous Size"]),
        .menu("window.toggleNavigator", "toggle navigator", ["View", "Navigators", "Hide Navigator"]),
        .menu("window.toggleInspector", "toggle inspector", ["View", "Inspectors", "Show Inspector"]),
        .menu("window.toggleDebugArea", "toggle debug area", ["View", "Debug Area", "Show Debug Area"]),

        // help
        .menu("help.docs", "developer documentation", ["Help", "Developer Documentation"]),
        .menu("help.hig", "human interface guidelines", ["Help", "Human Interface Guidelines"]),
        .menu("help.swiftBook", "the swift book", ["Help", "Swift Programming Language Book"]),
        .menu("help.searchDocs", "search docs for selection", ["Help", "Search Documentation for Selected Text"]),

        // open — Xcode has no terminal at all, only the LLDB console, so ours is ours.
        Command(id: "open.terminal", title: "terminal",
                searchText: "toggle the terminal at the project root",
                action: .companion("toggleTerminal")),

        // quit
        .menu("quit.xcode", "quit xcode", ["Xcode", "Quit Xcode"]),
        Command(id: "quit.companion", title: "quit companion",
                searchText: "quit Autographe for Xcode", action: .companion("quit")),
        Command(id: "companion.reload", title: "reload commands",
                searchText: "reload Xcode commands", action: .companion("reloadMenus")),

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

    // MARK: - bindings

    static let bindings: [([KeyEvent], String)] = [
        // Doom's own top-level keys, kept exactly.
        ([" "], "picker.files"),          // SPC SPC — find file in project
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

        // t — toggles
        (["t", "m"], "toggle.minimap"),
        (["t", "w"], "toggle.wrap"),
        (["t", "v"], "toggle.vim"),
        (["t", "i"], "toggle.invisibles"),
        (["t", "l"], "toggle.lineNumbers"),
        (["t", "a"], "toggle.authors"),
        (["t", "c"], "toggle.coverage"),
        (["t", "g"], "toggle.scopeGuides"),

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
        (["w", "f"], "window.choosePane"),
        (["w", "a"], "window.nextArea"),
        (["w", "O"], "window.editorOnly"),
        (["w", "t"], "window.tabToWindow"),
        (["w", "m"], "window.mergeAll"),
        (["w", "H"], "window.tileLeft"),
        (["w", "L"], "window.tileRight"),
        (["w", "F"], "window.tileFull"),
        (["w", "r"], "window.previousSize"),
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

        // o — open
        (["o", "t"], "open.terminal"),
        (["o", "f"], "file.revealInFinder"),

        // h — help
        (["h", "d"], "help.docs"),
        (["h", "h"], "help.hig"),
        (["h", "s"], "help.swiftBook"),
        (["h", "k"], "code.quickHelp"),
        (["h", "/"], "help.searchDocs"),

        // q — quit
        (["q", "q"], "quit.companion"),
        (["q", "X"], "quit.xcode"),
        (["q", "r"], "companion.reload"),
    ]

    /// Every menu path the shipped keymap depends on, for a startup sanity check against
    /// the live menu bar.
    public static var menuPaths: [[String]] {
        commands.compactMap(\.menuPath)
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
