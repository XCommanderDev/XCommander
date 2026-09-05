import Testing
@testable import CompanionCore

/// Guards on the shipped keymap. `DefaultKeymap.build()` uses `try!`, so a conflict
/// introduced while editing the tables would crash at launch; these find it in the suite.
@Suite("Shipped keymap")
struct DefaultKeymapTests {

    @Test("the shipped keymap builds without conflicts")
    func buildsCleanly() {
        let (registry, keymap) = DefaultKeymap.build()
        #expect(registry.count > 80)
        #expect(!keymap.rows(at: [], in: registry).isEmpty)
    }

    /// Mnemonics are the product. If a group loses its title or moves, that is a
    /// deliberate decision and should have to be made deliberately.
    @Test("the top level is the Doom-aligned namespace")
    func topLevel() {
        let (registry, keymap) = DefaultKeymap.build()
        let rows = keymap.rows(at: [], in: registry)
        let groups = Dictionary(uniqueKeysWithValues: rows.filter(\.isGroup).map { ($0.key, $0.title) })
        #expect(groups["b"] == "buffers")
        #expect(groups["c"] == "code")
        #expect(groups["d"] == "debug")
        #expect(groups["f"] == "files")
        #expect(groups["g"] == "git")
        #expect(groups["h"] == "help")
        #expect(groups["m"] == "make")
        #expect(groups["p"] == "project")
        #expect(groups["s"] == "search")
        #expect(groups["t"] == "toggles")
        #expect(groups["w"] == "windows")
        #expect(groups["x"] == "text")
    }

    /// Doom's own top-level keys, kept exactly, because that is the muscle memory we are
    /// trying to reuse.
    @Test("Doom's single-key entries are bound as Doom binds them")
    func doomKeys() {
        let (_, keymap) = DefaultKeymap.build()
        func id(_ key: KeyEvent) -> String? {
            if case .some(.command(let id)) = keymap.entry(at: [key]) { return id }
            return nil
        }
        #expect(id(KeyEvent(.space)) == "picker.files")   // SPC SPC
        #expect(id(KeyEvent(":")) == "picker.commands")   // SPC :  is M-x
        #expect(id(KeyEvent(",")) == "picker.buffers")
        #expect(id(KeyEvent("/")) == "search.project")
    }

    @Test("every binding resolves to a registered command")
    func everyBindingIsRegistered() {
        let (registry, keymap) = DefaultKeymap.build()
        for (sequence, id) in DefaultKeymap.bindings {
            guard case .some(.command(let found)) = keymap.entry(at: sequence) else {
                Issue.record("\(sequence.map(\.display).joined(separator: " ")) does not resolve")
                continue
            }
            #expect(found == id)
            #expect(registry.command(id: id) != nil, "\(id) is bound but not registered")
        }
    }

    /// Two commands on the same menu path is always a copy-paste slip, and it shows up as
    /// a duplicated row in the palette. That is how this one was found.
    @Test("no two commands point at the same menu path")
    func noDuplicateMenuPaths() {
        var seen: [String: String] = [:]
        for command in DefaultKeymap.commands {
            guard let path = command.menuPath?.joined(separator: " > ") else { continue }
            if let existing = seen[path] {
                Issue.record("\(command.id) and \(existing) both point at \(path)")
            }
            seen[path] = command.id
        }
    }

    @Test("command ids are unique")
    func uniqueIDs() {
        let ids = DefaultKeymap.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// A command nobody can reach is dead weight, and the palette is the reason every one
    /// of them is reachable even without a binding.
    @Test("every registered command is reachable from the palette")
    func everyCommandIsSearchable() {
        let (registry, _) = DefaultKeymap.build()
        for command in registry.all {
            #expect(!command.searchText.isEmpty, "\(command.id) has no search text")
            #expect(!command.title.isEmpty, "\(command.id) has no title")
        }
    }

    @Test("an upper-case literal is the lower-case key with Shift")
    func upperCaseMeansShift() {
        #expect(KeyEvent(stringLiteral: "S") == KeyEvent("s", [.shift]))
        #expect(KeyEvent(stringLiteral: " ") == KeyEvent(.space))
    }

    @Test("the leader is Shift-Space and renders as ⇧SPC")
    func leader() {
        #expect(DefaultKeymap.leader == KeyEvent(.space, [.shift]))
        #expect(DefaultKeymap.leader.display == "⇧SPC")
    }

    @Test("status is derived, and permission outranks everything")
    func status() {
        #expect(CompanionStatus.derive(hasAccessibility: false, secureInputActive: true,
                                       xcodeFrontmost: true) == .needsAccessibility)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: true,
                                       xcodeFrontmost: true) == .pausedBySecureInput)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: false,
                                       xcodeFrontmost: false) == .idle)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: false,
                                       xcodeFrontmost: true) == .armed)
    }

    /// Every text transform should be both bound and registered: they are the features
    /// Xcode does not have, so a missing one is a missing product feature.
    @Test("every text transform is registered and bound")
    func transformsAreAllReachable() {
        let (registry, keymap) = DefaultKeymap.build()
        let registered = registry.all.compactMap { command -> TextTransform? in
            if case .transform(let t) = command.action { return t }
            return nil
        }
        #expect(Set(registered).count == TextTransform.allCases.count)
        for command in registry.all {
            guard case .transform = command.action else { continue }
            #expect(keymap.binding(for: command.id) != nil, "\(command.id) has no binding")
        }
    }

    /// Same for the pickers: the workstream is "fuzzy everything", so every picker the
    /// product knows about must be openable.
    @Test("every picker kind is registered and bound")
    func pickersAreAllReachable() {
        let (registry, keymap) = DefaultKeymap.build()
        var reachable = Set<PickerKind>()
        for command in registry.all {
            guard case .picker(let kind) = command.action else { continue }
            if keymap.binding(for: command.id) != nil { reachable.insert(kind) }
        }
        // `menuSlice` is generic and has no binding of its own by design.
        let expected = Set(PickerKind.allCases).subtracting([.menuSlice])
        #expect(reachable == expected, "unreachable pickers: \(expected.subtracting(reachable))")
    }
}
