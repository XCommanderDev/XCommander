import Testing
@testable import CompanionCore

/// The trie is the heart of the interaction model, so it is tested for the shapes that
/// break it rather than only the shape that works.
@Suite("Keymap trie")
struct KeymapTests {

    /// Hand-built rather than taken from `DefaultKeymap`, so the test states its own
    /// expectations and does not move when the shipped keymap does.
    private func sample() throws -> Keymap {
        var map = Keymap()
        let titles: [[KeyEvent]: String] = [[KeyEvent("b")]: "build"]
        try map.bind([KeyEvent("b"), KeyEvent("b")],
                     to: .menu("build.build", "build", ["Product", "Build"]),
                     groupTitles: titles)
        try map.bind([KeyEvent("b"), KeyEvent("c")],
                     to: .menu("build.clean", "clean", ["Product", "Clean Build Folder…"]),
                     groupTitles: titles)
        try map.bind([KeyEvent("q")],
                     to: Command(id: "quit", title: "quit", action: .companion("quit")))
        return map
    }

    @Test("a one-key binding lands directly on a command")
    func singleKey() throws {
        let map = try sample()
        guard case .some(.command(let c)) = map.entry(at: [KeyEvent("q")]) else {
            Issue.record("expected a command at q"); return
        }
        #expect(c.id == "quit")
    }

    @Test("a two-key binding creates a titled group on the way")
    func groupCreated() throws {
        let map = try sample()
        guard case .some(.group(let title, let kids)) = map.entry(at: [KeyEvent("b")]) else {
            Issue.record("expected a group at b"); return
        }
        #expect(title == "build")
        #expect(kids.count == 2)
    }

    @Test("walking off the trie returns nothing rather than guessing")
    func missingKey() throws {
        let map = try sample()
        #expect(map.entry(at: [KeyEvent("z")]) == nil)
        #expect(map.entry(at: [KeyEvent("b"), KeyEvent("z")]) == nil)
    }

    /// The rule that keeps the engine timeout-free: a node is a command or a group,
    /// never both. Each half of that rule is a separate failure, so both are tested.
    @Test("a command cannot become a prefix")
    func commandInThePath() throws {
        var map = try sample()
        #expect(throws: KeymapError.self) {
            try map.bind([KeyEvent("q"), KeyEvent("x")],
                         to: Command(id: "x", title: "x", action: .companion("x")))
        }
    }

    @Test("a group cannot also be a command")
    func groupWhereCommandExpected() throws {
        var map = try sample()
        #expect(throws: KeymapError.self) {
            try map.bind([KeyEvent("b")],
                         to: Command(id: "x", title: "x", action: .companion("x")))
        }
    }

    @Test("binding the same sequence twice is refused rather than silently overwritten")
    func duplicate() throws {
        var map = try sample()
        #expect(throws: KeymapError.self) {
            try map.bind([KeyEvent("q")],
                         to: Command(id: "other", title: "other", action: .companion("o")))
        }
    }

    @Test("an empty sequence is not a binding")
    func emptySequence() {
        var map = Keymap()
        #expect(throws: KeymapError.emptySequence) {
            try map.bind([], to: Command(id: "x", title: "x", action: .companion("x")))
        }
    }

    @Test("rows at the root list the groups; rows in a group list its commands")
    func rows() throws {
        let map = try sample()
        let root = map.rows(at: [])
        #expect(root.map(\.key) == ["b", "q"])
        #expect(root.first { $0.key == "b" }?.isGroup == true)
        #expect(root.first { $0.key == "b" }?.label == "+build")
        #expect(root.first { $0.key == "q" }?.label == "quit")

        let build = map.rows(at: [KeyEvent("b")])
        #expect(build.map(\.key) == ["b", "c"])
        #expect(build.allSatisfy { !$0.isGroup })
    }

    @Test("rows for a leaf or a missing prefix are empty, not a crash")
    func rowsForNonGroup() throws {
        let map = try sample()
        #expect(map.rows(at: [KeyEvent("q")]).isEmpty)
        #expect(map.rows(at: [KeyEvent("z")]).isEmpty)
    }

    /// Plain string ordering puts every capital before every lower-case letter, which
    /// would separate `s` from `S` by the whole alphabet. They belong next to each other.
    @Test("rows sort lower case before upper case for the same letter")
    func rowOrdering() {
        let rows = [
            WhichKeyRow(key: "S", title: "save all", isGroup: false),
            WhichKeyRow(key: "b", title: "build", isGroup: false),
            WhichKeyRow(key: "s", title: "save", isGroup: false),
        ].sorted()
        #expect(rows.map(\.key) == ["b", "s", "S"])
    }
}

/// The panel shows Xcode's own binding next to ours, which means a row has to carry
/// enough for the app to look that binding up.
@Suite("Which-key rows carry their menu path")
struct WhichKeyRowTests {

    @Test("a leaf row carries the menu path; a group row does not")
    func rowsCarryMenuPath() throws {
        var map = Keymap()
        try map.bind([KeyEvent("b"), KeyEvent("b")],
                     to: .menu("build.build", "build", ["Product", "Build"]),
                     groupTitles: [[KeyEvent("b")]: "build"])

        let group = try #require(map.rows(at: []).first)
        #expect(group.isGroup)
        #expect(group.menuPath == nil)

        let leaf = try #require(map.rows(at: [KeyEvent("b")]).first)
        #expect(leaf.menuPath == ["Product", "Build"])
        // Core leaves the shortcut empty: it depends on the running Xcode and the layout.
        #expect(leaf.shortcut == nil)
    }

    @Test("a companion command has no menu path to look up")
    func companionCommandHasNoPath() throws {
        var map = Keymap()
        try map.bind([KeyEvent("q")],
                     to: Command(id: "quit", title: "quit", action: .companion("quit")))
        let row = try #require(map.rows(at: []).first)
        #expect(row.menuPath == nil)
    }
}
