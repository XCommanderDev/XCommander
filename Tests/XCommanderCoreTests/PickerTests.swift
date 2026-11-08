import Testing
@testable import XCommanderCore

/// The picker's whole behaviour lives in `PickerSession`, so all of it is testable without
/// a window. These read as the key sequences a user actually types.
@Suite("Picker session")
struct PickerTests {

    private func picker() -> PickerSession {
        PickerSession(title: "Commands", items: [
            PickerItem(id: "build", title: "Product > Build", detail: "⇧SPC m m"),
            PickerItem(id: "run", title: "Product > Run", detail: "⇧SPC m r"),
            PickerItem(id: "test", title: "Product > Test", detail: "⇧SPC m t"),
            PickerItem(id: "clean", title: "Product > Clean Build Folder…"),
            PickerItem(id: "disabled", title: "Product > Stop", isEnabled: false),
        ])
    }

    @Test("everything shows before anything is typed")
    func initiallyEverything() {
        let p = picker()
        #expect(p.rows.count == 5)
        #expect(p.selection == 0)
        #expect(p.selectedItem?.id == "build")
    }

    @Test("typing filters and re-ranks")
    func typing() {
        var p = picker()
        #expect(p.press(KeyEvent("r")) == .updated)
        #expect(p.query == "r")
        #expect(p.rows.allSatisfy { $0.item.title.lowercased().contains("r") })
        #expect(p.selectedItem?.id == "run")
    }

    @Test("backspace and Ctrl-u undo typing")
    func erasing() {
        var p = picker()
        _ = p.press(KeyEvent("r"))
        _ = p.press(KeyEvent("u"))
        #expect(p.query == "ru")
        _ = p.press(KeyEvent(.delete))
        #expect(p.query == "r")
        _ = p.press(KeyEvent("u", [.control]))
        #expect(p.query == "")
        #expect(p.rows.count == 5)
    }

    @Test("Ctrl-w deletes a word")
    func deleteWord() {
        var p = picker()
        for c in "product bu" { _ = p.press(KeyEvent(c)) }
        _ = p.press(KeyEvent("w", [.control]))
        #expect(p.query == "product ")
    }

    @Test("arrows, Ctrl-n/p and Tab all move the selection")
    func movement() {
        var p = picker()
        _ = p.press(KeyEvent(.down))
        #expect(p.selection == 1)
        _ = p.press(KeyEvent("n", [.control]))
        #expect(p.selection == 2)
        _ = p.press(KeyEvent(.up))
        #expect(p.selection == 1)
        _ = p.press(KeyEvent("p", [.control]))
        #expect(p.selection == 0)
        _ = p.press(KeyEvent(.tab))
        #expect(p.selection == 1)
    }

    /// Held down, a list that dead-ends at the bottom feels broken. Wrapping is what you
    /// want when you are driving it blind from the home row.
    @Test("selection wraps at both ends")
    func wrapping() {
        var p = picker()
        _ = p.press(KeyEvent(.up))
        #expect(p.selection == 4)
        _ = p.press(KeyEvent(.down))
        #expect(p.selection == 0)
    }

    @Test("Return chooses the selected row")
    func choosing() {
        var p = picker()
        _ = p.press(KeyEvent(.down))
        #expect(p.press(KeyEvent(.return)) == .chosen(
            PickerItem(id: "run", title: "Product > Run", detail: "⇧SPC m r")))
    }

    /// Xcode's menus are context-dependent, so a row can be offered and then be
    /// unavailable. Choosing it does nothing rather than firing something else.
    @Test("a disabled row cannot be chosen")
    func disabledRow() {
        var p = picker()
        for c in "stop" { _ = p.press(KeyEvent(c)) }
        #expect(p.selectedItem?.id == "disabled")
        #expect(p.press(KeyEvent(.return)) == .ignored)
    }

    @Test("Esc and Ctrl-g both cancel")
    func cancelling() {
        var p = picker()
        #expect(p.press(.escape) == .cancelled)
        #expect(p.press(KeyEvent("g", [.control])) == .cancelled)
    }

    /// The bug this prevents: type until one row is left, move the cursor down, delete a
    /// character so the list grows again, and press Return on a row that is no longer the
    /// one that was highlighted.
    @Test("the selection is clamped when the list shrinks")
    func selectionClamped() {
        var p = picker()
        _ = p.press(KeyEvent(.down))
        _ = p.press(KeyEvent(.down))
        #expect(p.selection == 2)
        for c in "build" { _ = p.press(KeyEvent(c)) }
        #expect(p.selection < p.rows.count)
        #expect(p.selectedItem != nil)
    }

    @Test("a query that matches nothing leaves an empty list and no selection")
    func noMatches() {
        var p = picker()
        for c in "zzzz" { _ = p.press(KeyEvent(c)) }
        #expect(p.rows.isEmpty)
        #expect(p.selectedItem == nil)
        #expect(p.press(KeyEvent(.return)) == .ignored)
    }

    @Test("space is part of the query, not a command")
    func spaceTypes() {
        var p = picker()
        _ = p.press(KeyEvent(.space))
        #expect(p.query == " ")
    }
}

/// A command must be findable by its name *and* its description. Found on screen: typing
/// "balance" ranked Xcode's "Balance Delimiters" above our own "balance panes", because
/// that command was searchable only by its description, "make the panes equal".
@Suite("Picker matching versus display")
struct PickerMatchTextTests {

    @Test("matching uses matchText while the row still shows title")
    func matchesOnMatchText() {
        var picker = PickerSession(title: "Commands", items: [
            PickerItem(id: "pane.balance", title: "balance panes",
                       matchText: "balance panes make the panes equal"),
            PickerItem(id: "menu", title: "Editor > Selection > Balance Delimiters"),
        ])
        for c in "make" { _ = picker.press(KeyEvent(c)) }
        #expect(picker.rows.count == 1)
        // Found by its description, but still displayed by its name.
        #expect(picker.selectedItem?.title == "balance panes")
    }

    @Test("a command is still findable by its visible name")
    func matchesOnName() {
        var picker = PickerSession(title: "Commands", items: [
            PickerItem(id: "pane.balance", title: "balance panes",
                       matchText: "balance panes make the panes equal"),
        ])
        for c in "balan" { _ = picker.press(KeyEvent(c)) }
        #expect(picker.rows.count == 1)
    }

    @Test("matchText defaults to the title so ordinary rows are unaffected")
    func defaultsToTitle() {
        let item = PickerItem(id: "a", title: "alpha")
        #expect(item.matchText == "alpha")
    }
}
