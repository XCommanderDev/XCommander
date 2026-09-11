import Testing
@testable import AutographeCore

@Suite("Picker row ids")
struct PickerTargetTests {

    @Test("a bare id is a command")
    func command() {
        #expect(PickerTarget.parse("picker.files") == .command("picker.files"))
    }

    @Test("a menu id splits on the control character, not on a printable one")
    func menu() {
        let id = "menu:Product\u{1}Destination\u{1}My Mac"
        #expect(PickerTarget.parse(id) == .menu(["Product", "Destination", "My Mac"]))
    }

    /// Xcode has menu items with `>` and `:` in their titles, which is why the separator is
    /// a control character. A menu path must survive both.
    @Test("menu titles may contain punctuation")
    func menuPunctuation() {
        let id = "menu:Editor\u{1}Fix All Issues: > now"
        #expect(PickerTarget.parse(id) == .menu(["Editor", "Fix All Issues: > now"]))
    }

    /// The encoder and the parser are the pair that matters: a menu path has to survive the
    /// round trip, whatever is in the titles.
    @Test("a menu path round-trips through its id")
    func menuRoundTrip() {
        let path = ["Editor", "Structure", "Re-Indent: > all"]
        #expect(PickerTarget.parse(PickerTarget.menuID(path)) == .menu(path))
    }

    /// `tab:` is parsed *before* `symbol:`/`match:`, which take the last colon as a line
    /// number. Ordered the other way, "tab:0:1" reads as the file "tab:0" at line 1 — which
    /// is a plausible-looking wrong answer rather than an error, so it is pinned here.
    @Test("a tab id is coordinates, not a path with a line")
    func tabIsNotAFileWithALine() {
        #expect(PickerTarget.parse("tab:0:1") == .tab(pane: 0, index: 1))
        #expect(PickerTarget.parse(PickerTarget.tabID(pane: 2, index: 11))
                == .tab(pane: 2, index: 11))
    }

    /// A malformed tab id falls back to being a command id rather than crashing or
    /// inventing coordinates. Rows come from our own encoder, so this is defence in depth.
    @Test("a malformed tab id is not forced into coordinates")
    func malformedTab() {
        #expect(PickerTarget.parse("tab:x:1") == .command("tab:x:1"))
        #expect(PickerTarget.parse("tab:1") == .command("tab:1"))
    }

    @Test("xed takes a line only when there is one")
    func xedArguments() {
        #expect(PickerTarget.xedArguments(path: "/tmp/a.swift", line: nil) == ["/tmp/a.swift"])
        #expect(PickerTarget.xedArguments(path: "/tmp/a.swift", line: 42)
                == ["--line", "42", "/tmp/a.swift"])
        // Line 0 is what an unset line looks like when it arrives as an Int, and `xed --line 0`
        // is an error rather than "the top of the file".
        #expect(PickerTarget.xedArguments(path: "/tmp/a.swift", line: 0) == ["/tmp/a.swift"])
    }

    @Test("a file id carries no line")
    func file() {
        #expect(PickerTarget.parse("file:/tmp/a/Helper.swift")
                == .file(path: "/tmp/a/Helper.swift", line: nil))
    }

    @Test("symbol and match ids carry a line")
    func fileWithLine() {
        #expect(PickerTarget.parse("symbol:/tmp/a/Helper.swift:42")
                == .file(path: "/tmp/a/Helper.swift", line: 42))
        #expect(PickerTarget.parse("match:/tmp/a/Helper.swift:7")
                == .file(path: "/tmp/a/Helper.swift", line: 7))
    }

    /// The reason the line is read from the end: a macOS path may legally contain a colon,
    /// and splitting from the front would take the first one and produce a path that does
    /// not exist plus a line that is not a number.
    @Test("a path containing a colon still parses")
    func colonInPath() {
        #expect(PickerTarget.parse("match:/tmp/My: Notes/Helper.swift:12")
                == .file(path: "/tmp/My: Notes/Helper.swift", line: 12))
    }

    /// A malformed line is not a reason to refuse to open the file — but the trailing text
    /// is kept, because a macOS filename may legally end in `:notaline` and truncating it
    /// would invent a path that does not exist. Better to try opening what we were given.
    @Test("an unparseable line is treated as part of the path")
    func badLine() {
        #expect(PickerTarget.parse("symbol:/tmp/a/Helper.swift:notaline")
                == .file(path: "/tmp/a/Helper.swift:notaline", line: nil))
    }
}

@Suite("Project-relative paths")
struct ProjectPathTests {

    @Test("an ordinary file under the root loses the root")
    func plain() {
        #expect(ProjectPath.relative(of: "/a/proj/Sources/App.swift", under: "/a/proj")
                == "Sources/App.swift")
    }

    @Test("a trailing slash on the root changes nothing")
    func trailingSlash() {
        #expect(ProjectPath.relative(of: "/a/proj/App.swift", under: "/a/proj/")
                == "App.swift")
    }

    /// The bug this exists for: `/tmp` is a symlink to `/private/tmp`, so the root and the
    /// walked file disagreed by exactly eight characters and every label was cut at the
    /// wrong offset — `config.json` came out as `scratch/config.json`.
    @Test("a file outside the root returns nil instead of a mangled slice")
    func mismatch() {
        #expect(ProjectPath.relative(of: "/private/tmp/proj/config.json", under: "/tmp/proj")
                == nil)
    }

    /// A sibling whose name merely starts with the root's is not inside it.
    @Test("a prefix that is not a directory boundary does not count")
    func notABoundary() {
        #expect(ProjectPath.relative(of: "/a/project-notes/x.md", under: "/a/project") == nil)
    }
}
