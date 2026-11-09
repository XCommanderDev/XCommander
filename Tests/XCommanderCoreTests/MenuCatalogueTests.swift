import Foundation
import Testing
@testable import XCommanderCore

/// These tests exist because Xcode 27 renamed four of the menu items this app binds and the
/// keymap, which named menu *paths*, lost all four silently. The catalogue keys on
/// `AXIdentifier` instead, and the case that matters most is the one in
/// `titleChangeDoesNotBreakABinding`: Apple may rewrite the title, and the binding holds.
///
/// The fixture is a real capture of Xcode 27.0 (27A266) taken with `xcmdr snapshot`,
/// checked in so these run headless — no Xcode, no Accessibility permission, no CI runner
/// with a GUI. That is also how this app will go on supporting an Xcode long after it stops
/// being installed on anyone's machine.
@Suite("Menu catalogue")
struct MenuCatalogueTests {

    // MARK: - fixtures

    /// The repo's checked-in capture, found relative to this file so the test target needs
    /// no resource bundle.
    static func xcode27() throws -> MenuSnapshot {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XCommanderCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("Fixtures/Xcode-27A266.json")
        return try MenuSnapshot.decode(Data(contentsOf: url))
    }

    static func snapshot(_ entries: [MenuEntry], build: String = "26A100",
                         major: Int = 26,
                         inputSource: String? = "com.apple.keylayout.US") -> MenuSnapshot {
        MenuSnapshot(release: XcodeRelease(version: "\(major).0", build: build, major: major),
                     capturedAt: "2026-01-01T00:00:00Z",
                     context: "a fixture",
                     inputSource: inputSource,
                     entries: entries)
    }

    // MARK: - resolution

    @Test("an identifier resolves whatever the item is called")
    func resolvesByIdentifier() {
        let catalogue = MenuCatalogue(Self.snapshot([
            MenuEntry(identifier: "formatFile:", title: "Format File with ‘swift-format’",
                      path: ["Editor", "Structure", "Format File with ‘swift-format’"]),
        ]))
        #expect(catalogue.isBound(MenuRef("formatFile:")))
        #expect(!catalogue.isBound(MenuRef("formatNothing:")))
    }

    /// The whole point of the refactor, stated as a test: the Xcode 26 title and the Xcode 27
    /// title differ, one `MenuRef` answers for both.
    @Test("a title Apple changed does not break a binding")
    func titleChangeDoesNotBreakABinding() throws {
        let ref = MenuRef("toggleComments:")

        let xcode26 = MenuCatalogue(Self.snapshot([
            MenuEntry(identifier: "toggleComments:", title: "Toggle Comments",
                      path: ["Editor", "Structure", "Toggle Comments"]),
        ]))
        let xcode27 = MenuCatalogue(try Self.xcode27())

        #expect(xcode26.isBound(ref))
        #expect(xcode27.isBound(ref))
        guard case .bound(let then, _) = xcode26.resolve(ref),
              case .bound(let now, _) = xcode27.resolve(ref) else {
            Issue.record("expected both to bind"); return
        }
        #expect(then.title == "Toggle Comments")
        #expect(now.title == "Comment Selection")
    }

    @Test("a shared identifier is ambiguous until the ref names a title")
    func sharedIdentifierNeedsATitle() {
        let entries = ["File", "History", "Quick Help"].map {
            MenuEntry(identifier: "showInspectorWithChoiceFromSender:", title: $0,
                      path: ["View", "Inspectors", $0])
        }
        let catalogue = MenuCatalogue(Self.snapshot(entries))

        guard case .ambiguous(let all) = catalogue.resolve(
            MenuRef("showInspectorWithChoiceFromSender:")) else {
            Issue.record("expected ambiguity"); return
        }
        #expect(all.count == 3)

        let ref = MenuRef("showInspectorWithChoiceFromSender:", title: "Quick Help")
        guard case .bound(let hit, _) = catalogue.resolve(ref) else {
            Issue.record("expected the titled ref to bind"); return
        }
        #expect(hit.title == "Quick Help")
    }

    @Test("alternates cover Apple renaming the action itself")
    func alternates() {
        let catalogue = MenuCatalogue(Self.snapshot([
            MenuEntry(identifier: "newFormatFile:", title: "Format File",
                      path: ["Editor", "Structure", "Format File"]),
        ]))
        #expect(catalogue.isBound(MenuRef("formatFile:", alternates: ["newFormatFile:"])))
    }

    /// The fallback rule, stated three ways, because it was once removed on principle and
    /// had to come back on evidence.
    ///
    /// The danger that justified removing it was never *paths*; it was **prefix** matching,
    /// which let `File > Close “` land on whatever document happened to be open. An exact
    /// path cannot do that. So: the identifier always wins when it resolves, the path
    /// catches the eight toggles whose identifier does not, and nothing matches loosely.
    @Test("the identifier wins whenever it resolves")
    func identifierBeatsPath() {
        let catalogue = MenuCatalogue(Self.snapshot([
            MenuEntry(identifier: "formatFile:", title: "Format File",
                      path: ["Editor", "Structure", "Format File"]),
            MenuEntry(identifier: "somethingElse:", title: "Close Project",
                      path: ["File", "Close Project"]),
        ]))
        let ref = MenuRef("formatFile:", path: ["File", "Close Project"])
        guard case .bound(let entry, let via) = catalogue.resolve(ref) else {
            Issue.record("expected the identifier to bind"); return
        }
        #expect(via == .identifier)
        #expect(entry.title == "Format File")
    }

    @Test("the path catches a ref whose identifier has moved out from under it")
    func pathCatchesAMovedIdentifier() {
        // What Xcode 27 really does to `Editor > Minimap`: same item, different identifier
        // from one reading to the next.
        let catalogue = MenuCatalogue(Self.snapshot([
            MenuEntry(identifier: "Show Minimap", title: "Minimap", path: ["Editor", "Minimap"]),
        ]))
        let ref = MenuRef("toggleMinimapShown:", path: ["Editor", "Minimap"])
        guard case .bound(let entry, let via) = catalogue.resolve(ref) else {
            Issue.record("expected the path to bind"); return
        }
        #expect(via == .path)
        #expect(entry.title == "Minimap")
    }

    /// The prefix match is gone and must stay gone.
    @Test("a path that is not exactly right matches nothing at all")
    func noLooseMatching() {
        let catalogue = MenuCatalogue(Self.snapshot([
            MenuEntry(identifier: "topLevelEditorContext_closeDocument:",
                      title: "Close “main.swift”", path: ["File", "Close “main.swift”"]),
        ]))
        #expect(!catalogue.isBound(MenuRef("gone:", path: ["File", "Close “"])))
        #expect(catalogue.isBound(MenuRef("topLevelEditorContext_closeDocument:")))
    }

    @Test("an item with no identifier is reachable by path, and says so")
    func pathOnly() {
        let catalogue = MenuCatalogue(Self.snapshot([
            MenuEntry(identifier: "", title: "Halves",
                      path: ["Window", "Move & Resize", "Halves"]),
        ]))
        let ref = MenuRef.pathOnly(["Window", "Move & Resize", "Halves"])
        #expect(ref.isPathOnly)
        #expect(catalogue.isBound(ref))
        #expect(catalogue.unnamedEntries.count == 1)
    }

    // MARK: - the diff

    @Test("the diff separates churn Apple absorbed from a command it removed")
    func diffCategories() {
        let before = Self.snapshot([
            MenuEntry(identifier: "toggleComments:", title: "Toggle Comments",
                      path: ["Editor", "Structure", "Toggle Comments"]),
            MenuEntry(identifier: "newEditorOnRight:", title: "Editor Pane On Right",
                      path: ["File", "New", "Editor Pane On Right"]),
            MenuEntry(identifier: "buildActiveRunContext:", title: "Build",
                      path: ["Product", "Build"], cmdChar: "B", cmdModifiers: 0),
        ])
        let after = Self.snapshot([
            MenuEntry(identifier: "toggleComments:", title: "Comment Selection",
                      path: ["Editor", "Structure", "Comment Selection"]),
            MenuEntry(identifier: "buildActiveRunContext:", title: "Build",
                      path: ["Product", "Build"], cmdChar: "B", cmdModifiers: 1),
            MenuEntry(identifier: "newCodingAssistant:", title: "Conversation",
                      path: ["File", "New", "Conversation"]),
        ], build: "27A266", major: 27)

        let diff = CatalogueDiff.between(before, and: after)
        #expect(diff.added.map(\.identifier) == ["newCodingAssistant:"])
        #expect(diff.removed.map(\.identifier) == ["newEditorOnRight:"])
        #expect(diff.retitled.map(\.identifier) == ["toggleComments:"])
        #expect(diff.retitled.first?.after == "Comment Selection")
        #expect(diff.rebound.map(\.identifier) == ["buildActiveRunContext:"])
        // A rename inside the same submenu is not a move.
        #expect(diff.moved.isEmpty)
    }

    @Test("an identifier that moved submenu is reported as moved")
    func diffMoves() {
        let before = Self.snapshot([
            MenuEntry(identifier: "findInWorkspace:", title: "Find in Workspace",
                      path: ["Edit", "Find", "Find in Workspace"]),
        ])
        let after = Self.snapshot([
            MenuEntry(identifier: "findInWorkspace:", title: "Find in Workspace",
                      path: ["Find", "Find in Workspace"]),
        ])
        #expect(CatalogueDiff.between(before, and: after).moved.map(\.identifier)
                == ["findInWorkspace:"])
    }

    /// Without this the diff would report every unnamed item as removed-and-added on every
    /// capture, because there is nothing to follow them by.
    @Test("items with no identifier take no part in the diff")
    func diffIgnoresUnnamed() {
        let before = Self.snapshot([
            MenuEntry(identifier: "", title: "Halves", path: ["Window", "Move & Resize", "Halves"]),
        ])
        let after = Self.snapshot([
            MenuEntry(identifier: "", title: "Quarters", path: ["Window", "Move & Resize", "Quarters"]),
        ])
        #expect(CatalogueDiff.between(before, and: after).isEmpty)
    }

    /// The 28 layout-specific characters in a French capture would all read as rebound
    /// against a US one, and none of them would be Apple's doing.
    @Test("shortcuts are not compared across keyboard layouts")
    func shortcutsGatedOnLayout() {
        let french = Self.snapshot([
            MenuEntry(identifier: "stopActiveRunContext:", title: "Stop",
                      path: ["Product", "Stop"], cmdChar: ";", cmdModifiers: 0),
        ], inputSource: "com.apple.keylayout.French")
        let us = Self.snapshot([
            MenuEntry(identifier: "stopActiveRunContext:", title: "Stop",
                      path: ["Product", "Stop"], cmdChar: ".", cmdModifiers: 0),
        ], inputSource: "com.apple.keylayout.US")

        let across = CatalogueDiff.between(french, and: us)
        #expect(!across.shortcutsCompared)
        #expect(across.rebound.isEmpty)
        #expect(across.isEmpty)

        let within = CatalogueDiff.between(french, and: Self.snapshot([
            MenuEntry(identifier: "stopActiveRunContext:", title: "Stop",
                      path: ["Product", "Stop"], cmdChar: ";", cmdModifiers: 1),
        ], inputSource: "com.apple.keylayout.French"))
        #expect(within.shortcutsCompared)
        #expect(within.rebound.map(\.identifier) == ["stopActiveRunContext:"])
    }

    @Test("a snapshot that does not name its keyboard is never compared on shortcuts")
    func shortcutsNeedAKnownLayout() {
        let anonymous = Self.snapshot([
            MenuEntry(identifier: "buildActiveRunContext:", title: "Build",
                      path: ["Product", "Build"], cmdChar: "B", cmdModifiers: 0),
        ], inputSource: nil)
        let diff = CatalogueDiff.between(anonymous, and: Self.snapshot([
            MenuEntry(identifier: "buildActiveRunContext:", title: "Build",
                      path: ["Product", "Build"], cmdChar: "B", cmdModifiers: 1),
        ], inputSource: nil))
        #expect(!diff.shortcutsCompared)
        #expect(diff.rebound.isEmpty)
    }

    @Test("two captures of the same Xcode diff to nothing")
    func diffIsStable() throws {
        let snapshot = try Self.xcode27()
        #expect(CatalogueDiff.between(snapshot, and: snapshot).isEmpty)
    }

    // MARK: - the support floor

    @Test("Xcode 27 is the floor")
    func supportFloor() {
        #expect(XcodeRelease(version: "27.0", build: "27A266", major: 27).isSupported)
        #expect(XcodeRelease(version: "27.1", build: "27A9269", major: 27).isSupported)
        #expect(!XcodeRelease(version: "26.4", build: "26F100", major: 26).isSupported)
    }

    // MARK: - the shipped snapshot

    @Test("the checked-in Xcode 27 snapshot is what was measured")
    func fixtureShape() throws {
        let catalogue = MenuCatalogue(try Self.xcode27())
        #expect(catalogue.release.build == "27A266")
        #expect(catalogue.release.major == 27)
        #expect(catalogue.release.isSupported)
        #expect(catalogue.entries.count == 752)
        #expect(catalogue.inputSource == "com.apple.keylayout.French")
        #expect(catalogue.unnamedEntries.count == 9)
        #expect(catalogue.identifierCount == 552)
    }

    /// **Titles move under you within one Xcode, not just between two.**
    ///
    /// `formatFile:` was read as `Format File` in one capture and
    /// `Format File with ‘swift-format’` in another, minutes apart, on the same build — the
    /// title depends on what Xcode considers the active editor. So this asserts what is
    /// actually stable (the action resolves, and lands in the submenu it belongs to) and
    /// deliberately does **not** pin a title, because pinning one is the mistake the whole
    /// catalogue exists to stop making.
    @Test("the commands whose titles move still resolve by identifier")
    func movingTitlesStillResolve() throws {
        let catalogue = MenuCatalogue(try Self.xcode27())
        let cases: [(identifier: String, parent: [String])] = [
            ("formatFile:", ["Editor", "Structure"]),
            ("formatSelection:", ["Editor", "Structure"]),
            ("toggleComments:", ["Editor", "Structure"]),
            ("newWindowForTab:", ["File", "New"]),
        ]
        for (identifier, parent) in cases {
            guard case .bound(let entry, let via) = catalogue.resolve(MenuRef(identifier)) else {
                Issue.record("\(identifier) did not resolve"); continue
            }
            #expect(via == .identifier)
            #expect(Array(entry.path.dropLast()) == parent)
        }
    }

    /// The eight toggles that made the exact-path fallback necessary. Their identifier is
    /// `toggleMinimapShown:` in one reading and `Show Minimap` in another, so the path is
    /// what actually finds them — and the audit is expected to say so.
    @Test("the Editor toggles resolve, by path, and the catalogue admits it")
    func togglesResolveByPath() throws {
        let catalogue = MenuCatalogue(try Self.xcode27())
        let toggles = ["toggle.minimap", "toggle.wrap", "toggle.vim", "toggle.invisibles",
                       "toggle.lineNumbers", "toggle.authors", "toggle.coverage",
                       "toggle.scopeGuides"]
        for id in toggles {
            guard let command = DefaultKeymap.menuCommands.first(where: { $0.id == id }) else {
                Issue.record("\(id) is not in the keymap"); continue
            }
            #expect(catalogue.isBound(command.menuRef!))
            #expect(catalogue.route(of: command.menuRef!) == .path)
        }
    }

    /// Everything else must resolve the right way. A binding quietly falling back to a path
    /// is how the fragile key creeps back in.
    @Test("nothing but those eight leans on a path")
    func onlyTogglesUsePaths() throws {
        let catalogue = MenuCatalogue(try Self.xcode27())
        let byPath = DefaultKeymap.menuCommands
            .filter { catalogue.route(of: $0.menuRef!) == .path }
            .map(\.id)
        #expect(byPath.count == 8)
        #expect(byPath.allSatisfy { $0.hasPrefix("toggle.") })
    }

    /// `toggleNavigator:` is one item for both states, which is why the catalogue needs no
    /// equivalent of the old Show/Hide sibling search.
    @Test("a toggle is one identifier, not a Show and a Hide")
    func togglesAreOneItem() throws {
        let catalogue = MenuCatalogue(try Self.xcode27())
        guard case .bound(let navigator, _) = catalogue.resolve(MenuRef("toggleNavigator:")) else {
            Issue.record("toggleNavigator: did not resolve"); return
        }
        #expect(navigator.title == "Show Navigator" || navigator.title == "Hide Navigator")
    }

    @Test("a submenu still answers as a list, for the pickers")
    func submenuListing() throws {
        let catalogue = MenuCatalogue(try Self.xcode27())
        #expect(catalogue.items(under: ["Editor", "Syntax Coloring"]).count == 57)
        // Xcode 27 replaced the Theme submenu with a dialog, and the catalogue says so
        // plainly rather than presenting an empty picker.
        #expect(catalogue.items(under: ["Editor", "Theme"]).isEmpty)
        #expect(catalogue.isBound(MenuRef("editThemes:")))
    }

    @Test("the shipped snapshot says which keyboard it was read through")
    func fixtureRecordsItsKeyboard() throws {
        let snapshot = try Self.xcode27()
        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.inputSource == "com.apple.keylayout.French")
        #expect(CatalogueDiff.between(snapshot, and: snapshot).shortcutsCompared)
    }

    @Test("a snapshot survives a round trip")
    func roundTrip() throws {
        let original = try Self.xcode27()
        let again = try MenuSnapshot.decode(original.encoded())
        #expect(again.entries.count == original.entries.count)
        #expect(again.release == original.release)
        #expect(CatalogueDiff.between(original, and: again).isEmpty)
    }

    // MARK: - redaction

    @Test("a shared snapshot names no one's projects, devices, windows or schemes")
    func redactionReplacesPersonalNames() {
        let snapshot = Self.snapshot([
            MenuEntry(identifier: "_openRecentDocument:", title: "Secret.xcodeproj",
                      path: ["File", "Open Recent", "Secret.xcodeproj"]),
            MenuEntry(identifier: "clearRecentDocuments:", title: "Clear Menu",
                      path: ["File", "Open Recent", "Clear Menu"]),
            MenuEntry(identifier: "_userSelectedRunDestinationMenuItem:", title: "Sam’s iPhone",
                      path: ["Product", "Destination", "Sam’s iPhone"]),
            MenuEntry(identifier: "_userSelectedRunDestinationMenuItem:", title: "Sam’s iPad",
                      path: ["Product", "Destination", "Devices", "Sam’s iPad"]),
            MenuEntry(identifier: "_activateWorkspaceWindowController:", title: "Secret — App.swift",
                      path: ["Window", "Secret — App.swift"]),
            MenuEntry(identifier: "_selectScheme:", title: "Secret", path: ["Product", "Scheme", "Secret"]),
            MenuEntry(identifier: "", title: "Getting Process List…",
                      path: ["Debug", "Attach to Process", "Getting Process List…"]),
            MenuEntry(identifier: "attach:", title: "Diary (412)",
                      path: ["Debug", "Attach to Process", "Diary (412)"]),
            MenuEntry(identifier: "buildActiveRunContext:", title: "Build", path: ["Product", "Build"]),
        ])
        let redacted = snapshot.redacted()
        let titles = redacted.entries.map(\.title)
        #expect(titles == ["Recent item 1", "Clear Menu", "Run destination 1", "Run destination 2",
                           "Window 1", "Scheme 1", "Getting Process List…", "Process 1", "Build"])
        // The item stays where it was, under its identifier, so audits and diffs don't move.
        #expect(redacted.entries[3].path == ["Product", "Destination", "Devices", "Run destination 2"])
        #expect(redacted.entries.map(\.identifier) == snapshot.entries.map(\.identifier))
        #expect(!titles.joined().contains("Secret") && !titles.joined().contains("Sam"))
    }

    /// The fixture is public. A capture taken before redaction existed held the maintainer's
    /// recent projects and device names; this keeps the next one honest.
    @Test("the checked-in snapshot is already redacted")
    func fixtureIsRedacted() throws {
        let fixture = try Self.xcode27()
        #expect(fixture.redacted().entries == fixture.entries)
    }
}

/// The support floor, as the menu bar states it.
///
/// Xcode 27 is the first release this app was measured against, and Xcode 27 itself needs
/// macOS 26.6 — so nobody who can run it is stuck below the line. The alternative to saying
/// so is a user on 26 pressing keys that quietly do nothing.
@Suite("Unsupported Xcode")
struct UnsupportedXcodeStatusTests {

    private func status(_ xcode: XcodeRelease?) -> CompanionStatus {
        CompanionStatus.derive(hasAccessibility: true, secureInputActive: false,
                               xcodeFrontmost: true, enabled: true, xcode: xcode)
    }

    @Test("an Xcode below the floor is named, not silently tolerated")
    func tooOld() {
        #expect(status(XcodeRelease(version: "26.4", build: "26F100", major: 26))
                == .unsupportedXcode("26.4"))
        #expect(status(XcodeRelease(version: "26.4", build: "26F100", major: 26)).faultSymbol != nil)
    }

    @Test("a supported Xcode arms as usual")
    func supported() {
        #expect(status(XcodeRelease(version: "27.0", build: "27A266", major: 27)) == .armed)
        #expect(status(XcodeRelease(version: "28.0", build: "28A1", major: 28)) == .armed)
    }

    /// No Xcode is not a fault: there is nothing to be incompatible with yet.
    @Test("no Xcode, or one that will not say its version, raises nothing")
    func silentWhenUnknown() {
        #expect(status(nil) == .armed)
        #expect(status(XcodeRelease(version: "unknown", build: "unknown", major: 0)) == .armed)
    }

    /// Permission and secure input come first: both mean nothing works at all, which is a
    /// more urgent thing to say than "this Xcode is old".
    @Test("the faults that stop everything outrank it")
    func precedence() {
        let old = XcodeRelease(version: "26.4", build: "26F100", major: 26)
        #expect(CompanionStatus.derive(hasAccessibility: false, secureInputActive: false,
                                       xcodeFrontmost: true, xcode: old) == .needsAccessibility)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: true,
                                       xcodeFrontmost: true, xcode: old) == .pausedBySecureInput)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: false,
                                       xcodeFrontmost: true, enabled: false, xcode: old) == .disabled)
    }

    @Test("the explanation names both versions, so the user knows what to do")
    func explanation() {
        let text = status(XcodeRelease(version: "26.4", build: "26F100", major: 26)).explanation
        #expect(text.contains("26.4"))
        #expect(text.contains("27"))
    }
}

/// The shortcut half, which the snapshot made visible: 38 of Xcode 27's menu items report a
/// shortcut that is not an ordinary character, and the character-only decoder turned each
/// into a key no keyboard has. Thirty of them Core can name; the other eight are the
/// function keys under `Debug > Step …` and dictation, and those it refuses.
@Suite("Menu shortcuts that are not characters")
struct MenuSpecialShortcutTests {

    @Test("an arrow arrives as a private-use scalar and decodes as an arrow")
    func arrows() {
        // `Navigate > Jump to Next Counterpart`: U+F700, mask 4 (control), ⌃⌘↑.
        let key = MenuShortcut.decode(character: "\u{F700}", mask: 4, virtualKey: 126)
        #expect(key == KeyEvent(.up, [.command, .control]))
        #expect(key?.display == "⌃⌘↑")
    }

    @Test("Return, Tab and Delete decode as themselves")
    func controlCharacters() {
        #expect(MenuShortcut.decode(character: "\r", mask: 6, virtualKey: 36)
                == KeyEvent(.return, [.command, .option, .control]))
        #expect(MenuShortcut.decode(character: "\u{9}", mask: 0, virtualKey: 48)
                == KeyEvent(.tab, [.command]))
        #expect(MenuShortcut.decode(character: "\u{8}", mask: 0, virtualKey: 51)
                == KeyEvent(.delete, [.command]))
    }

    /// `Debug > Step Over` is F6, and the debugger is the only part of Xcode's menu bar that
    /// uses the function row. Before these existed the panel showed those three commands
    /// with no shortcut at all, which taught the user less than Xcode's own menu does.
    @Test("the function row decodes, because the debugger needs it")
    func functionKeysDecode() {
        // U+F709 is `NSF6FunctionKey`; mask 8 means the shortcut has no Command.
        #expect(MenuShortcut.decode(character: "\u{F709}", mask: 8, virtualKey: 97)
                == KeyEvent(.f6))
        #expect(MenuShortcut.decode(character: "\u{F70A}", mask: 8, virtualKey: 98)
                == KeyEvent(.f7))
        #expect(MenuShortcut.decode(character: "\u{F70B}", mask: 8, virtualKey: 100)
                == KeyEvent(.f8))
        #expect(MenuShortcut.decode(character: "\u{F704}", mask: 0, virtualKey: 122)?.display == "⌘F1")
    }

    /// Dictation's microphone is what is left: a menu item whose "shortcut" is not a key.
    @Test("something that is not a key at all still decodes to nothing")
    func nonKeysAreRefused() {
        #expect(MenuShortcut.decode(character: "\u{1F3A4}", mask: 8, virtualKey: 128) == nil)
    }

    /// The three debugger commands the app binds, read from the real capture.
    @Test("the shipped debugger bindings carry their function keys")
    func debuggerShortcutsSurvive() throws {
        let catalogue = MenuCatalogue(try MenuCatalogueTests.xcode27())
        for (identifier, expected) in [("stepOver:", "F6"), ("stepInto:", "F7"), ("stepOut:", "F8")] {
            guard case .bound(let entry, _) = catalogue.resolve(MenuRef(identifier)) else {
                Issue.record("\(identifier) did not resolve"); continue
            }
            #expect(entry.shortcut?.display == expected)
        }
    }

    /// The AZERTY characters the menu really reports must not be caught by the filter.
    @Test("an ordinary character still decodes the old way")
    func ordinaryCharactersUnaffected() {
        #expect(MenuShortcut.decode(character: "Ù", mask: 5, virtualKey: nil)
                == MenuShortcut.decode(character: "Ù", mask: 5))
        #expect(MenuShortcut.decode(character: "B", mask: 0, virtualKey: nil)
                == KeyEvent("b", [.command]))
    }

    @Test("every shortcut in the shipped snapshot decodes without inventing a key")
    func fixtureShortcutsAreSane() throws {
        let catalogue = MenuCatalogue(try MenuCatalogueTests.xcode27())
        for entry in catalogue.entries {
            guard let shortcut = entry.shortcut else { continue }
            if case .character(let c) = shortcut.key {
                #expect(!(0xF700...0xF8FF).contains(c.unicodeScalars.first!.value),
                        "\(entry.path.joined(separator: " > ")) decoded to a private-use character")
            }
        }
    }
}
