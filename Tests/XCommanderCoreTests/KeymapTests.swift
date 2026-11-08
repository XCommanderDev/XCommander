import Testing
@testable import XCommanderCore

/// The trie is the heart of the interaction model, so it is tested for the shapes that
/// break it rather than only the shape that works.
@Suite("Keymap trie")
struct KeymapTests {

    /// Hand-built rather than taken from `DefaultKeymap`, so the test states its own
    /// expectations and does not move when the shipped keymap does.
    private func sample() throws -> (Keymap, CommandRegistry) {
        var registry = CommandRegistry()
        registry.register(.menu("make.build", "build", MenuRef("buildActiveRunContext:")))
        registry.register(.menu("make.clean", "clean", MenuRef("cleanActiveRunContext:")))
        registry.register(Command(id: "quit", title: "quit", action: .companion("quit")))

        var map = Keymap()
        let titles: [[KeyEvent]: String] = [[KeyEvent("m")]: "make"]
        try map.bind([KeyEvent("m"), KeyEvent("m")], to: "make.build", groupTitles: titles)
        try map.bind([KeyEvent("m"), KeyEvent("c")], to: "make.clean", groupTitles: titles)
        try map.bind([KeyEvent("q")], to: "quit")
        return (map, registry)
    }

    @Test("a one-key binding lands directly on a command id")
    func singleKey() throws {
        let (map, _) = try sample()
        guard case .some(.command(let id)) = map.entry(at: [KeyEvent("q")]) else {
            Issue.record("expected a command at q"); return
        }
        #expect(id == "quit")
    }

    @Test("a two-key binding creates a titled group on the way")
    func groupCreated() throws {
        let (map, _) = try sample()
        guard case .some(.group(let title, let kids)) = map.entry(at: [KeyEvent("m")]) else {
            Issue.record("expected a group at m"); return
        }
        #expect(title == "make")
        #expect(kids.count == 2)
    }

    @Test("walking off the trie returns nothing rather than guessing")
    func missingKey() throws {
        let (map, _) = try sample()
        #expect(map.entry(at: [KeyEvent("z")]) == nil)
        #expect(map.entry(at: [KeyEvent("m"), KeyEvent("z")]) == nil)
    }

    /// The rule that keeps the engine timeout-free: a node is a command or a group, never
    /// both. Each half is a separate failure, so both are tested.
    @Test("a command cannot become a prefix")
    func commandInThePath() throws {
        var (map, _) = try sample()
        #expect(throws: KeymapError.self) {
            try map.bind([KeyEvent("q"), KeyEvent("x")], to: "anything")
        }
    }

    @Test("a group cannot also be a command")
    func groupWhereCommandExpected() throws {
        var (map, _) = try sample()
        #expect(throws: KeymapError.self) {
            try map.bind([KeyEvent("m")], to: "anything")
        }
    }

    @Test("binding the same sequence twice is refused rather than silently overwritten")
    func duplicate() throws {
        var (map, _) = try sample()
        #expect(throws: KeymapError.self) {
            try map.bind([KeyEvent("q")], to: "other")
        }
    }

    @Test("an empty sequence is not a binding")
    func emptySequence() {
        var map = Keymap()
        #expect(throws: KeymapError.emptySequence) { try map.bind([], to: "x") }
    }

    /// The registry decision, in one test: the panel's titles come from the registry, so a
    /// command described in one place is described the same way everywhere.
    @Test("rows take their titles from the registry")
    func rowsFromRegistry() throws {
        let (map, registry) = try sample()
        let root = map.rows(at: [], in: registry)
        #expect(root.map(\.key) == ["m", "q"])
        #expect(root.first { $0.key == "m" }?.label == "+make")
        #expect(root.first { $0.key == "q" }?.label == "quit")

        let make = map.rows(at: [KeyEvent("m")], in: registry)
        #expect(make.map(\.key) == ["c", "m"])
        #expect(make.first { $0.key == "m" }?.title == "build")
        #expect(make.allSatisfy { !$0.isGroup })
    }

    /// **A key the panel prints and cannot run is the worst outcome available to a keyboard
    /// tool**: the user is told to press it, nothing happens, and they cannot tell a removed
    /// Xcode feature from a broken app. So a command the running Xcode does not offer is not
    /// drawn at all — a user on an Xcode that lost a command simply never learns there was one.
    @Test("a command the running Xcode does not have is not shown")
    func unavailableCommandsAreHidden() throws {
        let (map, registry) = try sample()
        let all = map.rows(at: [KeyEvent("m")], in: registry)
        #expect(all.count == 2)

        let filtered = map.rows(at: [KeyEvent("m")], in: registry,
                                isAvailable: { $0.id != "make.clean" })
        #expect(filtered.map(\.title) == ["build"])
    }

    /// Groups are structure, not commands, so nothing hides them. A group that empties out
    /// is a separate question and not one the panel should answer by guessing.
    @Test("filtering leaves groups alone")
    func groupsSurviveFiltering() throws {
        let (map, registry) = try sample()
        let top = map.rows(at: [], in: registry, isAvailable: { _ in false })
        #expect(top.filter { !$0.isGroup }.isEmpty)
        #expect(!top.isEmpty)
    }

    @Test("a row carries the menu item so the app can look its shortcut up")
    func rowsCarryMenuRef() throws {
        let (map, registry) = try sample()
        let row = try #require(map.rows(at: [KeyEvent("m")], in: registry).first { $0.key == "m" })
        #expect(row.menuRef == MenuRef("buildActiveRunContext:"))
    }

    @Test("rows for a leaf or a missing prefix are empty, not a crash")
    func rowsForNonGroup() throws {
        let (map, registry) = try sample()
        #expect(map.rows(at: [KeyEvent("q")], in: registry).isEmpty)
        #expect(map.rows(at: [KeyEvent("z")], in: registry).isEmpty)
    }

    /// The palette shows the binding beside each command, which is what makes it teach the
    /// keymap instead of competing with it. That needs the reverse lookup.
    @Test("a command's binding can be found from its id")
    func reverseLookup() throws {
        let (map, _) = try sample()
        #expect(map.binding(for: "make.build") == [KeyEvent("m"), KeyEvent("m")])
        #expect(map.binding(for: "quit") == [KeyEvent("q")])
        #expect(map.binding(for: "not.bound") == nil)
    }

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

@Suite("Command registry")
struct CommandRegistryTests {

    @Test("registering keeps order and allows lookup by id")
    func registerAndLookup() {
        var registry = CommandRegistry()
        registry.register(.menu("a", "alpha", MenuRef("alpha:")))
        registry.register(.menu("b", "bravo", MenuRef("bravo:")))
        #expect(registry.count == 2)
        #expect(registry.command(id: "a")?.title == "alpha")
        #expect(registry.all.map(\.id) == ["a", "b"])
    }

    @Test("re-registering an id replaces it without duplicating the order entry")
    func replacing() {
        var registry = CommandRegistry()
        registry.register(.menu("a", "alpha", MenuRef("alpha:")))
        registry.register(.menu("a", "changed", MenuRef("alpha:")))
        #expect(registry.count == 1)
        #expect(registry.all.count == 1)
        #expect(registry.command(id: "a")?.title == "changed")
    }

    /// The menu path is no longer written down in the keymap, so it cannot be the default
    /// search text any more. The palette asks the running Xcode where the item sits and
    /// searches that instead, which is both shorter here and right across a release that
    /// moves things.
    @Test("search text falls back to the title, not to a path the source no longer knows")
    func searchText() {
        let command = Command.menu("make.build", "build", MenuRef("buildActiveRunContext:"))
        #expect(command.title == "build")
        #expect(command.searchText == "build")
        #expect(command.menuRef == MenuRef("buildActiveRunContext:"))
    }
}
