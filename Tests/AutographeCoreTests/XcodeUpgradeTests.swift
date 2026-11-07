import Foundation
import Testing
@testable import AutographeCore

/// The rules that decide what this app believes about an Xcode it has not been tested on.
///
/// Every one of these was a defect first. Each test names the situation that produced it,
/// because each is a situation a real user is in on the day Apple ships something.
@Suite("Which Xcode")
struct XcodeTargetTests {

    private let release = XcodeInstance(pid: 100, bundlePath: "/Applications/Xcode.app",
                                        isActive: false, launchDate: Date(timeIntervalSince1970: 1_000))
    private let beta = XcodeInstance(pid: 200, bundlePath: "/Applications/Xcode-beta.app",
                                     isActive: false, launchDate: Date(timeIntervalSince1970: 2_000))

    @Test("the Xcode in front is the one keystrokes are going to")
    func frontmostWins() {
        var front = release
        front.isActive = true
        #expect(XcodeTarget.choose([front, beta], lastActive: beta.pid)?.pid == release.pid)
    }

    /// Switching to Terminal to run `xcmdr` must not move the app onto the other Xcode.
    @Test("with neither in front, the one last in front keeps the app's attention")
    func lastActiveWins() {
        #expect(XcodeTarget.choose([release, beta], lastActive: release.pid)?.pid == release.pid)
    }

    @Test("with no history, the most recently launched wins")
    func newestLaunchWins() {
        #expect(XcodeTarget.choose([release, beta])?.pid == beta.pid)
    }

    /// The Xcode that was last in front has quit — an update relaunching it looks like this.
    @Test("a last-active Xcode that has quit is forgotten, not chased")
    func quitLastActiveFallsBack() {
        #expect(XcodeTarget.choose([release, beta], lastActive: 999)?.pid == beta.pid)
    }

    @Test("no Xcode is no answer")
    func noneRunning() {
        #expect(XcodeTarget.choose([], lastActive: 100) == nil)
    }
}

/// When a record of a build is complete enough to act on.
///
/// The defect: the first scan of a new Xcode was compared against the old build's
/// accumulated menu. Xcode reopens on its Welcome window after an update, and a scan taken
/// there — measured on 27.2 — lacks 27 of the 115 shipped bindings, which would have been
/// hidden from the panel and reported as removed by Apple.
@Suite("Settling a new build")
struct SettlingTests {

    private func scan(editor: Bool?, _ identifiers: [String]) -> MenuSnapshot {
        MenuSnapshot(release: XcodeRelease(version: "28.0", build: "28A100", major: 28),
                     capturedAt: "2026-11-01T00:00:00Z", context: "a test",
                     inputSource: "com.apple.keylayout.US",
                     entries: identifiers.map { MenuEntry(identifier: $0, title: $0, path: ["M", $0]) },
                     editorScans: editor.map { $0 ? 1 : 0 })
    }

    @Test("a scan with no editor focused proves nothing is missing")
    func unfocusedScanIsUnsettled() {
        #expect(!scan(editor: false, ["a:"]).isSettled)
        #expect(!MenuCatalogue(scan(editor: false, ["a:"])).isSettled)
    }

    @Test("one scan with an editor focused settles the build, and stays settled")
    func editorScanSettles() {
        let navigator = scan(editor: false, ["a:"])
        let editing = scan(editor: true, ["a:", "toggleMinimapShown:"])
        let merged = navigator.merging(editing)
        #expect(merged.isSettled)
        #expect(merged.editorScans == 1)
        #expect(merged.merging(navigator).isSettled)
    }

    /// Snapshots written before `editorScans` existed have no opinion, and are treated as not
    /// having seen an editor: at worst one session shows every key.
    @Test("a snapshot from before the field existed reads as unsettled")
    func legacySnapshotIsUnsettled() throws {
        let legacy = scan(editor: nil, ["a:"])
        #expect(legacy.editorScans == nil)
        #expect(!legacy.isSettled)
        let json = String(decoding: try legacy.encoded(), as: UTF8.self)
        #expect(!json.contains("editorScans"))
        #expect(!(try MenuSnapshot.decode(legacy.encoded())).isSettled)
    }
}

/// What the first real upgrade (27.0 → 27.2) showed a diff must not call a rename.
@Suite("Titles that follow context")
struct ContextTitleTests {

    private func snapshot(_ entries: [MenuEntry]) -> MenuSnapshot {
        MenuSnapshot(release: XcodeRelease(version: "27.2", build: "27B51", major: 27),
                     capturedAt: "2026-11-07T00:00:00Z", context: "a test",
                     inputSource: "com.apple.keylayout.US", entries: entries)
    }

    @Test("a title that only names a different open file is not a rename")
    func quotedNamesAreContext() {
        let old = snapshot([MenuEntry(identifier: "compileFile:", title: "Compile “0 mach_msg2_trap”",
                                      path: ["Product", "Perform Action", "Compile “0 mach_msg2_trap”"])])
        let new = snapshot([MenuEntry(identifier: "compileFile:", title: "Compile “AppDelegate.swift”",
                                      path: ["Product", "Perform Action", "Compile “AppDelegate.swift”"])])
        #expect(CatalogueDiff.between(old, and: new).retitled.isEmpty)
        #expect(CatalogueDiff.contextFree("Bookmark “a.swift” Line 43") == "Bookmark “…” Line 43")
    }

    @Test("a real rename still is one")
    func realRenameSurvives() {
        let old = snapshot([MenuEntry(identifier: "toggleComments:", title: "Comment Selection",
                                      path: ["Editor", "Structure", "Comment Selection"])])
        let new = snapshot([MenuEntry(identifier: "toggleComments:", title: "Toggle Comments",
                                      path: ["Editor", "Structure", "Toggle Comments"])])
        #expect(CatalogueDiff.between(old, and: new).retitled.map(\.after) == ["Toggle Comments"])
    }

    /// Snapshots recorded before the scanner skipped `Xcode > Services` still contain it.
    @Test("system-owned menus take no part in a diff")
    func servicesAreTheSystems() {
        let old = snapshot([MenuEntry(identifier: "_processRequest:", title: "Activity Monitor",
                                      path: ["Xcode", "Services", "Activity Monitor"])])
        #expect(CatalogueDiff.between(old, and: snapshot([])).removed.isEmpty)
        #expect(MenuEntry.isSystemOwned(["Apple", "Recent Items"]))
        #expect(!MenuEntry.isSystemOwned(["Xcode", "Settings…"]))
    }

    /// The window list, recent projects, run destinations: the user's data, not Apple's API.
    @Test("a list-shaped identifier takes no part in renames")
    func listsAreUserData() {
        let window = "_activateWorkspaceWindowController:"
        let old = snapshot([MenuEntry(identifier: window, title: "A — x.swift", path: ["Window", "A — x.swift"]),
                            MenuEntry(identifier: window, title: "B — y.swift", path: ["Window", "B — y.swift"])])
        let new = snapshot([MenuEntry(identifier: window, title: "A — z.swift", path: ["Window", "A — z.swift"])])
        let diff = CatalogueDiff.between(old, and: new)
        #expect(diff.retitled.isEmpty)
        #expect(diff.removed.isEmpty)
    }
}

/// Files outlive the app that wrote them, in both directions.
@Suite("Snapshot schema")
struct SnapshotSchemaTests {

    @Test("a file from a newer app is refused by name, before its shape is trusted")
    func newerFileIsRefused() throws {
        let future = #"{"schemaVersion": 99, "something": "we have never heard of"}"#
        #expect(throws: MenuCatalogueSchema.NewerFile.self) {
            try MenuSnapshot.decode(Data(future.utf8))
        }
    }

    @Test("the checked-in capture is a version this code reads")
    func fixtureIsCurrent() throws {
        #expect(try MenuCatalogueTests.xcode27().schemaVersion <= MenuCatalogueSchema.current)
    }

    /// Its context says a source editor was focused for one of the three captures, so the
    /// audit may trust what is *missing* from it, not only what is there.
    @Test("the checked-in capture is settled")
    func fixtureIsSettled() throws {
        let fixture = try MenuCatalogueTests.xcode27()
        #expect(fixture.isSettled)
        #expect(fixture.context.contains("source editor focused"))
    }
}

/// Every leader is swallowed while Xcode is in front, so whatever Xcode put on the same
/// chord becomes unreachable. The settings window states that cost for each choice; these
/// tests make the statement checkable.
///
/// The defect: the note for `⌥Return` said it shadowed Focus Editor Pane, which in Xcode 27
/// is `⌃⇧⌘Return`, and the note for `⌃Space` did not mention that it hides Show Completions.
@Suite("What each leader hides")
struct LeaderShadowTests {

    @Test("every leader's note agrees with the Xcode 27 capture")
    func notesMatchXcode27() throws {
        let catalogue = MenuCatalogue(try MenuCatalogueTests.xcode27())
        for choice in LeaderChoice.allCases {
            let (undeclared, stale) = choice.unexpectedShadows(in: catalogue)
            #expect(undeclared.isEmpty, "\(choice.title) hides \(undeclared.map(\.identifier))")
            #expect(stale.isEmpty, "\(choice.title) claims \(stale) and Xcode 27 disagrees")
        }
    }

    @Test("the default leader hides nothing in Xcode 27's menus")
    func defaultIsFree() throws {
        let catalogue = MenuCatalogue(try MenuCatalogueTests.xcode27())
        #expect(catalogue.entries(withShortcut: LeaderChoice.default.event).isEmpty)
    }

    @Test("⌃Space hides Show Completions, and says so")
    func controlSpaceIsHonest() throws {
        let catalogue = MenuCatalogue(try MenuCatalogueTests.xcode27())
        let hidden = catalogue.entries(withShortcut: LeaderChoice.controlSpace.event)
        #expect(hidden.map(\.identifier) == ["complete:"])
        #expect(LeaderChoice.controlSpace.note?.contains("Show Completions") == true)
    }

    /// What a future Xcode would look like: a command Apple moves onto the default leader.
    @Test("a command moved onto a leader is caught")
    func newShadowIsCaught() {
        let catalogue = MenuCatalogue(MenuSnapshot(
            release: XcodeRelease(version: "28.0", build: "28A100", major: 28),
            capturedAt: "2026-11-01T00:00:00Z", context: "a test", inputSource: nil,
            entries: [MenuEntry(identifier: "showEverything:", title: "Show Everything",
                                path: ["View", "Show Everything"],
                                cmdChar: "\r", cmdModifiers: 2 | 8, cmdVirtualKey: 36)]))
        let (undeclared, _) = LeaderChoice.optionReturn.unexpectedShadows(in: catalogue)
        #expect(undeclared.map(\.identifier) == ["showEverything:"])
    }
}
