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
        // Still Doom's "search project", but ours (ripgrep) rather than Xcode's
        // find navigator, which keeps SPC s p.
        #expect(id(KeyEvent("/")) == "picker.search")
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

    /// A literal is the character the user sees, not a key plus a modifier — which is what
    /// makes one binding work on every keyboard layout. See `KeyIdentityTests`.
    @Test("a literal is the character as written")
    func literalIsTheCharacter() {
        #expect(KeyEvent(stringLiteral: "S") == KeyEvent("S"))
        #expect(KeyEvent(stringLiteral: "/") == KeyEvent("/"))
        #expect(KeyEvent(stringLiteral: " ") == KeyEvent(.space))
    }

    /// The synthesised pane commands, which have no Xcode menu item behind them, and the
    /// destination-modifier commands, which do. Both were added together because they are
    /// the two halves of "where does this land".
    @Test("swapping and sending are bound where vim puts them")
    func paneMovementBindings() {
        let built = DefaultKeymap.build()
        func id(_ keys: [KeyEvent]) -> String? {
            guard case .some(.command(let id)) = built.keymap.entry(at: keys) else { return nil }
            return id
        }
        #expect(id([KeyEvent("w"), KeyEvent("x")]) == "pane.swap")
        #expect(id([KeyEvent("w"), KeyEvent("H")]) == "pane.sendLeft")
        #expect(id([KeyEvent("w"), KeyEvent("J")]) == "pane.sendDown")
        #expect(id([KeyEvent("w"), KeyEvent("K")]) == "pane.sendUp")
        #expect(id([KeyEvent("w"), KeyEvent("L")]) == "pane.sendRight")
        #expect(id([KeyEvent("c"), KeyEvent("D")]) == "code.definitionInPane")
        #expect(id([KeyEvent("c"), KeyEvent("T")]) == "code.definitionInTab")
    }

    /// macOS window management moved a level down to free `w H/J/K/L`. A three-key binding
    /// exercises the trie's nesting, which nothing else in the shipped keymap does.
    @Test("os window commands live in a nested group, and it is titled")
    func nestedOSWindowGroup() {
        let built = DefaultKeymap.build()
        guard case .some(.group(let title, _)) = built.keymap.entry(at: [KeyEvent("w"), KeyEvent("W")])
        else {
            Issue.record("w W should be a group")
            return
        }
        #expect(title == "os window")
        guard case .some(.command(let id)) =
                built.keymap.entry(at: [KeyEvent("w"), KeyEvent("W"), KeyEvent("h")]) else {
            Issue.record("w W h should be a command")
            return
        }
        #expect(id == "window.tileLeft")
    }

    /// The left-hand pane. Every navigator must be registered *and* bound, because the
    /// failure this guards is silent: a navigator with no binding is simply unreachable, and
    /// nothing else in the suite would notice.
    @Test("every navigator is registered and bound")
    func everyNavigatorIsReachable() {
        let built = DefaultKeymap.build()
        for navigator in XcodeNavigator.allCases {
            guard let command = built.registry.command(id: navigator.commandID) else {
                Issue.record("\(navigator.rawValue) has no registered command")
                continue
            }
            #expect(command.action == .menuPath(navigator.menuPath))
            #expect(built.keymap.binding(for: navigator.commandID) != nil,
                    "\(navigator.rawValue) is registered but unreachable")
        }
    }

    /// The focusable areas, guarded the same way: a case added to `XcodeArea` and forgotten
    /// in the keymap is unreachable, and nothing else would notice.
    @Test("every focusable area is registered and bound")
    func everyAreaIsReachable() {
        let built = DefaultKeymap.build()
        for area in XcodeArea.allCases {
            guard let command = built.registry.command(id: area.commandID) else {
                Issue.record("\(area.rawValue) has no registered command")
                continue
            }
            #expect(command.action == .focus(area))
            #expect(built.keymap.binding(for: area.commandID) != nil,
                    "\(area.rawValue) is registered but unreachable")
        }
    }

    /// The three side panes each get a toggle, and all three are *named* as toggles. They
    /// were one-way for a while: each named a single spelling of a menu item whose title
    /// flips between `Show X` and `Hide X`, so `w n` could hide the navigator and never bring
    /// it back. The fix is in `XcodeContext`; this pins the commands themselves.
    @Test("each side pane has a toggle bound")
    func sidePaneToggles() {
        let built = DefaultKeymap.build()
        for id in ["window.toggleNavigator", "window.toggleInspector", "window.toggleDebugArea"] {
            #expect(built.registry.command(id: id) != nil, "\(id) is not registered")
            #expect(built.keymap.binding(for: id) != nil, "\(id) is unreachable")
        }
    }

    /// The raw value *is* Xcode's menu title, which is the point of storing it that way —
    /// one table instead of a mapping to get wrong. If someone ever prettifies a case name,
    /// this fails rather than the menu lookup going quietly dead at runtime.
    @Test("a navigator's menu path is built from Xcode's own name")
    func navigatorMenuPaths() {
        #expect(XcodeNavigator.sourceControl.menuPath == ["View", "Navigators", "Source Control"])
        #expect(XcodeNavigator.breakpoints.menuPath == ["View", "Navigators", "Breakpoints"])
        for navigator in XcodeNavigator.allCases {
            #expect(navigator.menuPath == ["View", "Navigators", navigator.rawValue])
        }
    }

    /// **The invariant behind offering a list instead of a key recorder.** Every choice on
    /// offer must be a keystroke that cannot be produced while writing code — otherwise the
    /// settings window becomes a way to reintroduce the defect the default was moved to
    /// avoid, and the user would have no way to know they had done it.
    @Test("every leader on offer is impossible to type as text")
    func everyLeaderChoiceIsSafe() {
        for choice in LeaderChoice.allCases {
            let event = choice.event
            switch event.key {
            case .character:
                Issue.record("\(choice.rawValue) is a character key")
            case .special:
                let chord: Modifiers = [.command, .option, .control]
                #expect(!event.modifiers.intersection(chord).isEmpty,
                        "\(choice.rawValue) has no chord modifier, so Shift alone would not stop it")
            }
        }
    }

    /// The default the app ships with must be one of the choices, or the popup opens showing
    /// something the user is not actually using.
    @Test("the shipped leader is one of the offered choices")
    func defaultLeaderIsOffered() {
        #expect(LeaderChoice.default.event == DefaultKeymap.leader)
        #expect(LeaderChoice.choice(for: DefaultKeymap.leader) == .optionReturn)
    }

    /// Each choice says what it shadows. An option with no note is one whose cost nobody
    /// checked, and the window would present it as free.
    @Test("every leader choice states what it costs")
    func everyChoiceHasANote() {
        for choice in LeaderChoice.allCases {
            #expect(!(choice.note ?? "").isEmpty, "\(choice.rawValue) has no note")
            #expect(!choice.title.isEmpty)
        }
    }

    @Test("the leader is Option-Return and renders as ⌥RET")
    func leader() {
        #expect(DefaultKeymap.leader == KeyEvent(.return, [.option]))
        #expect(DefaultKeymap.leader.display == "⌥RET")
    }

    /// The property that made us move off `⇧Space`, asserted rather than trusted.
    ///
    /// A leader that is a text-producing key can be typed by accident — a Shift held a beat
    /// too long across a word break — and the session cannot tell that from intent, so the
    /// next word runs as a command. This is the regression test for that whole class: the
    /// leader must not be something a person can produce while writing code.
    @Test("the leader cannot be typed as text")
    func leaderIsNotATextKey() {
        switch DefaultKeymap.leader.key {
        case .character:
            Issue.record("a character leader can be typed by accident")
        case .special(let special):
            // Space and Tab both insert; Return inserts too, but only as a chord does it
            // become unreachable, so the modifier is the load-bearing half.
            #expect(!DefaultKeymap.leader.modifiers.isEmpty,
                    "an unmodified \(special) is still a keystroke that lands in the file")
            let chord: Modifiers = [.command, .option, .control]
            #expect(!DefaultKeymap.leader.modifiers.intersection(chord).isEmpty,
                    "Shift alone does not stop a key producing text")
        }
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
        // Switched off from the menu, but permission still outranks it: a disabled app
        // that also lacks permission should say the thing the user must fix.
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: false,
                                       xcodeFrontmost: true, enabled: false) == .disabled)
        #expect(CompanionStatus.derive(hasAccessibility: false, secureInputActive: false,
                                       xcodeFrontmost: true, enabled: false) == .needsAccessibility)
    }

    /// The menu bar draws the brand mark for the three ordinary states and an SF Symbol
    /// only when something is wrong, so `faultSymbol` must be `nil` for exactly the three.
    @Test("only the fault states carry a symbol")
    func faultSymbols() {
        #expect(CompanionStatus.needsAccessibility.faultSymbol == "exclamationmark.triangle.fill")
        #expect(CompanionStatus.pausedBySecureInput.faultSymbol == "lock.fill")
        #expect(CompanionStatus.armed.faultSymbol == nil)
        #expect(CompanionStatus.idle.faultSymbol == nil)
        #expect(CompanionStatus.disabled.faultSymbol == nil)
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
        // Every kind is bound. `menuSlice` used to be excluded here "by design"; it was a
        // seam with no consumer whose implementation quietly opened the command palette
        // instead, so it was deleted rather than kept as a promise.
        let expected = Set(PickerKind.allCases)
        #expect(reachable == expected, "unreachable pickers: \(expected.subtracting(reachable))")
    }
}
