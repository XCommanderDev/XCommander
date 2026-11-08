import Testing
@testable import AutographeCore

/// The buffer list, as logic.
///
/// The reading of Xcode's tab bars is Accessibility work and lives in `XcodeContext`, where
/// it cannot be tested headlessly. Everything *decided* about the rows — what is shown, in
/// what order, and what is left out — is here, which is the same split the rest of the
/// project uses.
@Suite("Editor tabs")
struct EditorTabTests {

    private func tab(_ pane: Int, _ index: Int, _ title: String,
                     active: Bool = false, focusedPane: Bool = false) -> EditorTab {
        EditorTab(pane: pane, index: index, title: title,
                  isActive: active, isInFocusedPane: focusedPane)
    }

    /// Switching to the file you are already looking at is not a switch, and it is the row
    /// the picker would otherwise preselect — so the current one is dropped.
    @Test("the file you are looking at is left out")
    func currentIsExcluded() {
        let tabs = [
            tab(0, 0, "Picker.swift", active: true, focusedPane: true),   // the current file
            tab(0, 1, "Keymap.swift"),
        ]
        let rows = EditorTabList.rows(tabs)
        #expect(rows.map(\.title) == ["Keymap.swift"])
    }

    /// Only the *active tab of the focused pane* is current. An active tab in some other
    /// pane is still somewhere to go, and is exactly the row that makes a cross-pane buffer
    /// list worth having.
    @Test("an active tab in another pane is still offered")
    func activeElsewhereIsKept() {
        let tabs = [
            tab(0, 0, "Picker.swift", active: true, focusedPane: true),
            tab(1, 0, "Keymap.swift", active: true),
        ]
        let rows = EditorTabList.rows(tabs)
        #expect(rows.map(\.title) == ["Keymap.swift"])
        #expect(rows[0].detail == "pane 2 · showing")
    }

    @Test("rows are ordered as the panes sit on screen, then by tab position")
    func ordering() {
        let tabs = [
            tab(1, 1, "d.swift"),
            tab(0, 1, "b.swift"),
            tab(1, 0, "c.swift"),
            tab(0, 0, "a.swift"),
        ]
        #expect(EditorTabList.rows(tabs).map(\.title) == ["a.swift", "b.swift", "c.swift", "d.swift"])
    }

    /// "pane 1" against a single pane is noise that pushes the file name off the line.
    @Test("the pane is named only when there is more than one")
    func paneNamedOnlyWhenItDisambiguates() {
        let single = [tab(0, 0, "a.swift"), tab(0, 1, "b.swift")]
        #expect(EditorTabList.rows(single).allSatisfy { $0.detail == nil })

        let split = [tab(0, 0, "a.swift"), tab(1, 0, "b.swift")]
        #expect(EditorTabList.rows(split).map(\.detail) == ["pane 1", "pane 2"])
    }

    /// Panes are numbered from 1 for the reader and from 0 in the tree. Getting that wrong
    /// is invisible in a unit test that only checks ordering, so it is asserted directly.
    @Test("panes are presented one-based")
    func paneNumbersAreOneBased() {
        let rows = EditorTabList.rows([tab(0, 0, "a.swift"), tab(2, 0, "b.swift")])
        #expect(rows.map(\.detail) == ["pane 1", "pane 3"])
    }

    /// A tab is addressed by coordinates because its title is only a file name — two
    /// `main.swift` in different targets are indistinguishable, and no attribute carries a
    /// path. The row id has to survive the round trip to the thing that presses the tab.
    @Test("a row id round-trips to the tab it names")
    func idRoundTrip() {
        let rows = EditorTabList.rows([tab(0, 0, "a.swift"), tab(3, 7, "b.swift")])
        #expect(PickerTarget.parse(rows[0].id) == .tab(pane: 0, index: 0))
        #expect(PickerTarget.parse(rows[1].id) == .tab(pane: 3, index: 7))
    }

    /// Two files with the same name in different targets are the case that made coordinates
    /// necessary rather than paths. They must remain separately selectable.
    @Test("identically named files stay distinguishable")
    func duplicateNames() {
        let rows = EditorTabList.rows([tab(0, 0, "main.swift"), tab(1, 0, "main.swift")])
        #expect(rows.count == 2)
        #expect(rows[0].id != rows[1].id)
    }

    /// Selectable is not the same as **distinguishable**, and the original test only checked
    /// the first. Found by using it: Xcode had the same file open in two tabs of one pane and
    /// the picker drew two identical rows — same title, and the pane number cannot separate
    /// them because it is the same pane.
    @Test("repeats inside one pane are told apart by tab position")
    func duplicateTitlesInOnePane() {
        let rows = EditorTabList.rows([
            tab(0, 0, "KeyEvent.swift"),
            tab(0, 1, "KeyEvent.swift"),
            tab(0, 2, "MenuShortcut.swift"),
        ])
        #expect(rows.map(\.title) == ["KeyEvent.swift", "KeyEvent.swift", "MenuShortcut.swift"])
        #expect(rows.map(\.detail) == ["tab 1", "tab 2", nil])
    }

    /// The same name in two different panes needs nothing extra: the pane number already
    /// separates them, and adding a tab position there would be noise.
    @Test("repeats across panes are left to the pane number")
    func duplicateTitlesAcrossPanes() {
        let rows = EditorTabList.rows([tab(0, 0, "main.swift"), tab(1, 0, "main.swift")])
        #expect(rows.map(\.detail) == ["pane 1", "pane 2"])
    }

    /// The count is over the rows actually shown. If the current file is what made a title
    /// repeat, the remaining row is unique and should not be labelled as though it were not.
    @Test("a repeat that only existed because of the current file is not labelled")
    func duplicateResolvedByExclusion() {
        let rows = EditorTabList.rows([
            tab(0, 0, "KeyEvent.swift"),
            tab(0, 1, "KeyEvent.swift", active: true, focusedPane: true),   // excluded
        ])
        #expect(rows.map(\.title) == ["KeyEvent.swift"])
        #expect(rows[0].detail == nil)
    }

    @Test("pane, tab and showing read in that order when all three apply")
    func detailOrder() {
        let rows = EditorTabList.rows([
            tab(0, 0, "a.swift"),
            tab(1, 0, "main.swift"),
            tab(1, 1, "main.swift", active: true),
        ])
        #expect(rows.last?.detail == "pane 2 · tab 2 · showing")
    }

    @Test("no tabs means no rows, which is what sends the caller to its fallback")
    func empty() {
        #expect(EditorTabList.rows([]).isEmpty)
    }
}
