import Foundation

/// The keymap the app ships with.
///
/// Commands are named by **menu path**, not by a hardcoded shortcut. That is deliberate.
/// Xcode reports its own shortcuts as characters in the user's current keyboard layout, so
/// `Product > Stop` is `⌘.` on QWERTY and `⌘;` on French AZERTY — the same physical key,
/// a different character. A table of hardcoded characters would be wrong for half the
/// world on day one. Instead the app reads Xcode's real menu bar once at startup and
/// learns what each path is actually bound to; see `MenuIndex`.
///
/// It also means the keymap follows the user: if they have rebound something in Xcode, we
/// fire their binding, not the factory one.
public enum DefaultKeymap {

    /// `⇧Space`. Chosen over `⌥Space`, which is Alfred's hotkey on this machine.
    ///
    /// The trade is real: in Xcode's editor `⇧Space` types a space, so while Xcode is
    /// frontmost that keystroke is ours and a Shift held a moment too long across a word
    /// break loses the space. Doom avoids this by being modal; there is no insert mode
    /// here, so the collision cannot be resolved the same way.
    public static let leader = KeyEvent(.space, [.shift])

    public static func build() -> Keymap {
        var map = Keymap()
        let titles: [[KeyEvent]: String] = [
            [KeyEvent("b")]: "build",
            [KeyEvent("r")]: "run",
            [KeyEvent("t")]: "test",
            [KeyEvent("f")]: "file",
            [KeyEvent("n")]: "navigate",
            [KeyEvent("s")]: "search",
        ]

        for (sequence, command) in bindings {
            // A conflict here is a programming error in this file, not a runtime condition.
            try! map.bind(sequence, to: command, groupTitles: titles)
        }
        return map
    }

    /// Every path below was read off a real Xcode 26.6 menu bar, not written from memory.
    static let bindings: [([KeyEvent], Command)] = [
        // build
        (["b", "b"], .menu("build.build",   "build",           ["Product", "Build"])),
        (["b", "c"], .menu("build.clean",   "clean",           ["Product", "Clean Build Folder…"])),
        (["b", "k"], .menu("build.stop",    "stop",            ["Product", "Stop"])),
        (["b", "a"], .menu("build.analyze", "analyze",         ["Product", "Analyze"])),
        (["b", "d"], .menu("build.docs",    "documentation",   ["Product", "Build Documentation"])),

        // run
        (["r", "r"], .menu("run.run",       "run",             ["Product", "Run"])),
        (["r", "w"], .menu("run.noBuild",   "without building", ["Product", "Perform Action", "Run Without Building"])),
        (["r", "p"], .menu("run.profile",   "profile",         ["Product", "Profile"])),

        // test
        (["t", "t"], .menu("test.test",     "test",            ["Product", "Test"])),
        (["t", "a"], .menu("test.again",    "test again",      ["Product", "Perform Action", "Test Again"])),
        (["t", "w"], .menu("test.noBuild",  "without building", ["Product", "Perform Action", "Test Without Building"])),
        (["t", "c"], .menu("test.clear",    "clear results",   ["Product", "Clear Test Results"])),

        // file
        (["f", "f"], .menu("file.open",     "open quickly",    ["File", "Open Quickly…"])),
        (["f", "s"], .menu("file.save",     "save",            ["File", "Save"])),
        (["f", "S"], .menu("file.saveAll",  "save all",        ["File", "Save All"])),
        (["f", "d"], .menu("file.close",    "close document",  ["File", "Close Document"])),

        // navigate
        (["n", "d"], .menu("nav.definition", "jump to definition", ["Navigate", "Jump to Definition"])),
        (["n", "b"], .menu("nav.back",      "back",            ["Navigate", "Show Previous Location in History"])),
        (["n", "f"], .menu("nav.forward",   "forward",         ["Navigate", "Show Next Location in History"])),
        (["n", "i"], .menu("nav.nextIssue", "next issue",      ["Navigate", "Jump to Next Issue"])),
        (["n", "I"], .menu("nav.prevIssue", "previous issue",  ["Navigate", "Jump to Previous Issue"])),
        (["n", "c"], .menu("nav.callers",   "call hierarchy",  ["Find", "Find Call Hierarchy"])),

        // search
        (["s", "s"], .menu("find.find",     "find",            ["Find", "Find…"])),
        (["s", "p"], .menu("find.project",  "find in project", ["Find", "Find in Package"])),
        (["s", "n"], .menu("find.next",     "next match",      ["Find", "Find Next"])),
        (["s", "N"], .menu("find.previous", "previous match",  ["Find", "Find Previous"])),
        (["s", "r"], .menu("find.replace",  "find and replace", ["Find", "Find and Replace…"])),
    ]

    /// Every menu path the default keymap depends on, for the startup sanity check.
    public static var menuPaths: [[String]] {
        bindings.compactMap { _, command in
            if case .menuPath(let path) = command.action { return path }
            return nil
        }
    }
}

extension Command {
    static func menu(_ id: String, _ title: String, _ path: [String]) -> Command {
        Command(id: id, title: title, action: .menuPath(path))
    }
}

extension KeyEvent: ExpressibleByStringLiteral {
    /// Lets the table above read as `["b", "b"]`. A multi-character literal is a
    /// programming error in this file and traps immediately rather than silently
    /// binding something surprising.
    public init(stringLiteral value: String) {
        precondition(value.count == 1, "a KeyEvent literal is one character: '\(value)'")
        let c = value.first!
        // An upper-case letter in the table means the key pressed with Shift.
        self.init(.character(Character(value.lowercased())), c.isUppercase ? [.shift] : [])
    }
}
