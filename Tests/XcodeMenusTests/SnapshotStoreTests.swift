import Foundation
import Testing
@testable import XcodeMenus
@testable import XCommanderCore

/// The store is what turns "one scan of one context" into "what this Xcode can do".
///
/// It matters more than it looks. Hiding a key from the which-key panel is only safe if the
/// app is *sure* Xcode does not have the command, and a single scan is never sure: with no
/// editor focused whole submenus are missing, and `Debug >` fills in only mid-session. These
/// tests pin the accumulation that makes the difference.
@Suite("Snapshot store")
struct SnapshotStoreTests {

    private func temporaryStore() -> SnapshotStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "xcmdr-tests-\(UUID().uuidString)")
        return SnapshotStore(directory: directory)
    }

    private func snapshot(build: String, context: String, _ entries: [(String, [String])],
                          inputSource: String? = "com.apple.keylayout.US",
                          capturedAt: String = "2026-09-20T10:00:00Z") -> MenuSnapshot {
        MenuSnapshot(release: XcodeRelease(version: "27.0", build: build, major: 27),
                     capturedAt: capturedAt,
                     context: context,
                     inputSource: inputSource,
                     entries: entries.map { MenuEntry(identifier: $0.0, title: $0.1.last!, path: $0.1) })
    }

    @Test("a scan taken in one context is remembered, then widened by the next")
    func accumulates() throws {
        let store = temporaryStore()
        let idle = snapshot(build: "27A266", context: "no editor focused",
                            [("buildActiveRunContext:", ["Product", "Build"])])
        let editing = snapshot(build: "27A266", context: "a Swift file open",
                               [("toggleComments:", ["Editor", "Structure", "Comment Selection"])],
                               capturedAt: "2026-09-20T11:00:00Z")

        try store.record(idle)
        let merged = try store.record(editing)

        let catalogue = MenuCatalogue(merged)
        #expect(catalogue.isBound(MenuRef("buildActiveRunContext:")))
        #expect(catalogue.isBound(MenuRef("toggleComments:")))
        #expect(merged.context.contains("no editor focused"))
        #expect(merged.context.contains("a Swift file open"))
        #expect(merged.capturedAt == "2026-09-20T11:00:00Z")
    }

    @Test("what is recorded survives the process")
    func roundTrip() throws {
        let store = temporaryStore()
        try store.record(snapshot(build: "27A266", context: "one",
                                  [("buildActiveRunContext:", ["Product", "Build"])]))
        let reloaded = try #require(SnapshotStore(directory: store.directory).load(build: "27A266"))
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.release.build == "27A266")
    }

    /// Folding two Xcodes together would invent a menu neither of them has, and the app
    /// would then hide keys on the strength of it.
    @Test("two different builds never merge")
    func buildsStaySeparate() throws {
        let store = temporaryStore()
        try store.record(snapshot(build: "27A266", context: "x",
                                  [("buildActiveRunContext:", ["Product", "Build"])]))
        try store.record(snapshot(build: "28A100", context: "y",
                                  [("somethingNew:", ["Product", "New Thing"])]))
        let older = try #require(store.load(build: "27A266"))
        #expect(older.entries.count == 1)
        #expect(!MenuCatalogue(older).isBound(MenuRef("somethingNew:")))
        #expect(store.knownBuilds().count == 2)
    }

    @Test("the previous build is the one an upgrade moved away from")
    func previousBuild() throws {
        let store = temporaryStore()
        try store.record(snapshot(build: "27A266", context: "x",
                                  [("a:", ["A"])], capturedAt: "2026-09-01T00:00:00Z"))
        try store.record(snapshot(build: "28A100", context: "y",
                                  [("b:", ["B"])], capturedAt: "2026-10-01T00:00:00Z"))
        #expect(store.previousBuild(before: "28A100")?.release.build == "27A266")
        #expect(store.previousBuild(before: "27A266")?.release.build == "28A100")
    }

    /// The baseline for a report should be a build the store had seen properly, not one it
    /// glimpsed once with no editor focused.
    @Test("the previous build prefers one that has settled")
    func previousBuildPrefersSettled() throws {
        let store = temporaryStore()
        var settled = snapshot(build: "27A266", context: "x", [("a:", ["A"])],
                               capturedAt: "2026-09-01T00:00:00Z")
        settled.editorScans = 1
        try store.record(settled)
        try store.record(snapshot(build: "28A050", context: "a glimpse", [("b:", ["B"])],
                                  capturedAt: "2026-10-01T00:00:00Z"))
        #expect(store.previousBuild(before: "28A100")?.release.build == "27A266")
    }

    /// Someone tries a newer build of the app, then goes back. The older app must not write
    /// its smaller picture over the newer one's.
    @Test("a file from a newer app is never overwritten")
    func newerFileIsKept() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion": 99}"#.utf8)
        try future.write(to: store.url(forBuild: "27A266"))
        #expect(throws: MenuCatalogueSchema.NewerFile.self) {
            try store.record(snapshot(build: "27A266", context: "x", [("a:", ["A"])]))
        }
        #expect(try Data(contentsOf: store.url(forBuild: "27A266")) == future)
        #expect(store.load(build: "27A266") == nil)
    }

    /// A build identifier comes from Xcode's bundle and ends up in a filename.
    @Test("a build identifier cannot escape the store's directory")
    func sanitisesFilenames() {
        let store = temporaryStore()
        let url = store.url(forBuild: "../../etc/passwd")
        #expect(url.deletingLastPathComponent().path == store.directory.path)
        #expect(!url.lastPathComponent.contains("/"))
    }

    @Test("merging across keyboards stops claiming a layout")
    func mergingAcrossLayouts() {
        let french = snapshot(build: "27A266", context: "a", [("a:", ["A"])],
                              inputSource: "com.apple.keylayout.French")
        let us = snapshot(build: "27A266", context: "b", [("b:", ["B"])],
                          inputSource: "com.apple.keylayout.US")
        #expect(french.merging(us).inputSource == nil)
        #expect(french.merging(french).inputSource == "com.apple.keylayout.French")
    }
}

/// What the user is actually told, which is a file rather than a dialog.
@Suite("Change report")
struct ChangeReportTests {

    private func release(_ version: String, _ build: String) -> XcodeRelease {
        XcodeRelease(version: version, build: build, major: Int(version.split(separator: ".")[0])!)
    }

    @Test("a rename is reported as harmless, because it is")
    func renameIsReassuring() {
        var diff = CatalogueDiff()
        diff.retitled = [MenuChange(identifier: "toggleComments:",
                                    before: "Toggle Comments", after: "Comment Selection")]
        let report = ChangeReport(from: release("26.4", "26F100"), to: release("27.0", "27A266"),
                                  diff: diff, lostBindings: [])
        #expect(report.isWorthTelling)
        #expect(report.summaryLine.contains("Nothing you bound was lost"))
        #expect(report.markdown.contains("Comment Selection"))
        #expect(report.markdown.contains("Menu titles that changed"))
    }

    /// Measured on the 27.0 → 27.2 upgrade: seventeen "renames", nearly all context. Written
    /// down, but never worth interrupting anyone for.
    @Test("titles and removals are written down but do not interrupt")
    func onlyCostsInterrupt() {
        var diff = CatalogueDiff()
        diff.retitled = [MenuChange(identifier: "pauseOrContinue:", before: "Continue", after: "Pause")]
        diff.removed = [MenuEntry(identifier: "newGroup:", title: "Group", path: ["File", "New", "Group"])]
        let quiet = ChangeReport(from: release("27.0", "27A266"), to: release("27.2", "27B51"),
                                 diff: diff, lostBindings: [])
        #expect(quiet.isWorthTelling)
        #expect(!quiet.needsAttention)
        #expect(quiet.markdown.contains("Commands no longer seen"))

        let costly = ChangeReport(from: release("27.0", "27A266"), to: release("27.2", "27B51"),
                                  diff: diff, lostBindings: [("x.y", "y", "newGroup:")])
        #expect(costly.needsAttention)
    }

    @Test("a lost binding leads, and says what to do about it")
    func lostBindingLeads() {
        var diff = CatalogueDiff()
        diff.removed = [MenuEntry(identifier: "newEditorOnRight:", title: "Editor Pane On Right",
                                  path: ["File", "New", "Editor Pane On Right"])]
        let report = ChangeReport(from: release("26.4", "26F100"), to: release("27.0", "27A266"),
                                  diff: diff,
                                  lostBindings: [("window.paneRight", "pane on right", "newEditorOnRight:")])
        #expect(report.summaryLine.contains("removed 1 command"))
        #expect(report.markdown.contains("window.paneRight"))
        #expect(report.markdown.contains("config.toml"))
    }

    /// Apple adding forty commands nobody bound is not something to interrupt anyone about.
    @Test("additions alone are not worth telling anyone")
    func additionsAreQuiet() {
        var diff = CatalogueDiff()
        diff.added = [MenuEntry(identifier: "newCodingAssistant:", title: "Conversation",
                                path: ["File", "New", "Conversation"])]
        let report = ChangeReport(from: release("26.4", "26F100"), to: release("27.0", "27A266"),
                                  diff: diff, lostBindings: [])
        #expect(!report.isWorthTelling)
    }

    /// The summary used to say "renamed 0 commands" whenever only removals had happened.
    @Test("a report of removals alone says removals")
    func removalsAloneSaySo() {
        var diff = CatalogueDiff()
        diff.removed = [MenuEntry(identifier: "oldThing:", title: "Old Thing", path: ["View", "Old Thing"])]
        let report = ChangeReport(from: release("27.0", "27A266"), to: release("28.0", "28A100"),
                                  diff: diff, lostBindings: [])
        #expect(report.isWorthTelling)
        #expect(report.summaryLine == "Xcode 28.0 removed 1 command. Nothing you bound was lost.")
        #expect(!report.needsAttention)
        #expect(!report.summaryLine.contains("renamed"))
    }

    @Test("a lost binding is listed once, under the heading that says what to do")
    func lostBindingIsNotListedTwice() {
        var diff = CatalogueDiff()
        diff.removed = [
            MenuEntry(identifier: "boundThing:", title: "Bound", path: ["View", "Bound"]),
            MenuEntry(identifier: "otherThing:", title: "Other", path: ["View", "Other"]),
        ]
        let report = ChangeReport(from: release("27.0", "27A266"), to: release("28.0", "28A100"),
                                  diff: diff, lostBindings: [("view.bound", "bound", "boundThing:")])
        let unboundSection = report.markdown.components(separatedBy: "that you had not bound").last ?? ""
        #expect(unboundSection.contains("View > Other"))
        #expect(!unboundSection.contains("View > Bound"))
    }

    /// Apple moving a command onto the leader takes it from Xcode, silently. Said loudly.
    @Test("a command moved onto the leader is news")
    func newShadowIsNews() {
        let moved = MenuEntry(identifier: "showEverything:", title: "Show Everything",
                              path: ["View", "Show Everything"])
        let report = ChangeReport(from: release("27.0", "27A266"), to: release("28.0", "28A100"),
                                  diff: CatalogueDiff(), lostBindings: [],
                                  leader: "⌥RET", newlyShadowed: [moved])
        #expect(report.isWorthTelling)
        #expect(report.summaryLine.contains("Show Everything"))
        #expect(report.markdown.contains("View > Show Everything"))
    }

    @Test("the window note asks for a report rather than declaring a fault")
    func windowNoteIsAHint() {
        let finding = XcodeAXSchema.Finding(kind: .sourceEditor,
                                            assumption: "the source editor names itself “Source Editor”",
                                            holds: false, detail: "no text area with that description")
        let note = ChangeReport.windowNote(release: release("28.0", "28A100"), failed: [finding])
        #expect(note.contains("28A100"))
        #expect(note.contains("xcmdr doctor"))
        #expect(note.contains("Source Editor"))
    }

    @Test("shortcuts that were not compared say so rather than reading as unchanged")
    func uncomparedShortcuts() {
        var diff = CatalogueDiff()
        diff.shortcutsCompared = false
        diff.retitled = [MenuChange(identifier: "a:", before: "A", after: "B")]
        let report = ChangeReport(from: release("26.4", "26F100"), to: release("27.0", "27A266"),
                                  diff: diff, lostBindings: [])
        #expect(report.markdown.contains("different keyboard layouts"))
    }
}

/// The merge rule that live testing found: a toggle renames itself, and a union that did not
/// know that would turn one command into two and break its own lookup.
@Suite("Merging states, not just contexts")
struct MergeStateTests {

    private func snapshot(_ entries: [(String, [String])], at time: String) -> MenuSnapshot {
        MenuSnapshot(release: XcodeRelease(version: "27.0", build: "27A266", major: 27),
                     capturedAt: time, context: "c", inputSource: "com.apple.keylayout.US",
                     entries: entries.map { MenuEntry(identifier: $0.0, title: $0.1.last!, path: $0.1) })
    }

    @Test("a toggle seen in both states stays one command")
    func toggleDoesNotClone() {
        let closed = snapshot([("toggleNavigator:", ["View", "Navigators", "Show Navigator"])],
                              at: "2026-09-20T10:00:00Z")
        let open = snapshot([("toggleNavigator:", ["View", "Navigators", "Hide Navigator"])],
                            at: "2026-09-20T11:00:00Z")
        let merged = closed.merging(open)
        #expect(merged.entries.count == 1)
        guard case .bound(let entry, _) = MenuCatalogue(merged).resolve(MenuRef("toggleNavigator:")) else {
            Issue.record("a merged toggle must still resolve"); return
        }
        #expect(entry.title == "Hide Navigator")
    }

    /// The other half of the rule: an identifier that names many items *within* one capture
    /// is a list, and merging must not collapse it.
    @Test("a list-shaped identifier keeps all of its items")
    func listsSurviveMerging() {
        let a = snapshot([
            ("_userSelectedRunDestinationMenuItem:", ["Product", "Destination", "My Mac"]),
            ("_userSelectedRunDestinationMenuItem:", ["Product", "Destination", "iPhone 17"]),
        ], at: "2026-09-20T10:00:00Z")
        let b = snapshot([
            ("_userSelectedRunDestinationMenuItem:", ["Product", "Destination", "My Mac"]),
            ("_userSelectedRunDestinationMenuItem:", ["Product", "Destination", "iPad Air"]),
        ], at: "2026-09-20T11:00:00Z")
        let merged = a.merging(b)
        #expect(merged.entries.count == 3)
        #expect(MenuCatalogue(merged).items(under: ["Product", "Destination"]).count == 3)
    }
}
