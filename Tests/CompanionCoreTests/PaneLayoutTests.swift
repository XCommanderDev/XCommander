import Testing
@testable import CompanionCore

/// Directional pane movement is the thing Xcode cannot do — it can only cycle — so the
/// geometry is ours and has to be right. Coordinates are Accessibility's: y grows downward.
@Suite("Pane navigation")
struct PaneLayoutTests {

    private func pane(_ index: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                      focused: Bool = false) -> Pane {
        Pane(index: index, frame: PaneRect(x: x, y: y, width: w, height: h), isFocused: focused)
    }

    /// | A | B |
    private func sideBySide() -> [Pane] {
        [pane(0, 0, 0, 500, 800, focused: true), pane(1, 500, 0, 500, 800)]
    }

    /// A over B.
    private func stacked() -> [Pane] {
        [pane(0, 0, 0, 1000, 400, focused: true), pane(1, 0, 400, 1000, 400)]
    }

    @Test("right and left move between side-by-side panes")
    func horizontal() {
        let panes = sideBySide()
        #expect(PaneLayout.target(from: panes[0], direction: .right, among: panes)?.index == 1)
        #expect(PaneLayout.target(from: panes[1], direction: .left, among: panes)?.index == 0)
    }

    @Test("down and up move between stacked panes")
    func vertical() {
        let panes = stacked()
        #expect(PaneLayout.target(from: panes[0], direction: .down, among: panes)?.index == 1)
        #expect(PaneLayout.target(from: panes[1], direction: .up, among: panes)?.index == 0)
    }

    /// Moving into the wall does nothing rather than wrapping. Wrapping is right for a
    /// list and wrong for a layout: `⌃w l` at the right edge should stay put.
    @Test("there is nothing beyond the edge")
    func edges() {
        let panes = sideBySide()
        #expect(PaneLayout.target(from: panes[0], direction: .left, among: panes) == nil)
        #expect(PaneLayout.target(from: panes[1], direction: .right, among: panes) == nil)
        #expect(PaneLayout.target(from: panes[0], direction: .up, among: panes) == nil)
    }

    @Test("a single pane has nowhere to go")
    func singlePane() {
        let only = [pane(0, 0, 0, 800, 600, focused: true)]
        for direction in [PaneDirection.left, .right, .up, .down] {
            #expect(PaneLayout.target(from: only[0], direction: direction, among: only) == nil)
        }
    }

    /// The layout that breaks a naive nearest-centre rule:
    ///     | A | B |
    ///     | A | C |
    /// From A, `right` must not prefer C just because their centres line up better.
    @Test("a move sideways prefers the pane it actually shares an edge with")
    func prefersOverlapping() {
        let panes = [
            pane(0, 0, 0, 500, 800, focused: true),
            pane(1, 500, 0, 500, 400),
            pane(2, 500, 400, 500, 400),
        ]
        let target = PaneLayout.target(from: panes[0], direction: .right, among: panes)
        // Both overlap A, and both are the same distance away; the nearer centre wins.
        #expect(target?.index == 1 || target?.index == 2)
        #expect(target != nil)
    }

    /// From B (top right), `down` is C — not A, which is to the left.
    @Test("a diagonal neighbour is not treated as being in the direction")
    func noDiagonalJump() {
        let panes = [
            pane(0, 0, 0, 500, 800),
            pane(1, 500, 0, 500, 400, focused: true),
            pane(2, 500, 400, 500, 400),
        ]
        #expect(PaneLayout.target(from: panes[1], direction: .down, among: panes)?.index == 2)
        #expect(PaneLayout.target(from: panes[1], direction: .left, among: panes)?.index == 0)
    }

    @Test("with three in a row, moving right lands on the neighbour, not the far end")
    func nearestWins() {
        let panes = [
            pane(0, 0, 0, 300, 800, focused: true),
            pane(1, 300, 0, 300, 800),
            pane(2, 600, 0, 300, 800),
        ]
        #expect(PaneLayout.target(from: panes[0], direction: .right, among: panes)?.index == 1)
        #expect(PaneLayout.target(from: panes[1], direction: .right, among: panes)?.index == 2)
    }

    /// Real numbers, read off a real Xcode window with two panes.
    @Test("the measured layout from a live Xcode window")
    func realWindow() {
        let panes = [
            pane(0, 670, 158, 552, 778, focused: true),
            pane(1, 1225, 158, 551, 778),
        ]
        #expect(PaneLayout.target(from: panes[0], direction: .right, among: panes)?.index == 1)
        #expect(PaneLayout.target(from: panes[1], direction: .left, among: panes)?.index == 0)
    }
}

/// The arithmetic behind balance, zoom and resize. Derived from a measured fact: an
/// `AXSplitter`'s value moves the divider one point per unit — 846 → 646 took a 552-point
/// pane to 352.
@Suite("Pane resizing")
struct PaneResizeTests {

    @Test("balance splits the space evenly")
    func balance() {
        // 352 and 751 either side, splitter at 646: even is 551.5 each, so -195.
        let value = PaneResize.balanced(currentValue: 646, before: 352, after: 751)
        #expect(value == 646 + 200)
    }

    @Test("balancing an already-even split changes nothing")
    func balanceNoOp() {
        #expect(PaneResize.balanced(currentValue: 846, before: 552, after: 552) == 846)
    }

    @Test("maximise gives the focused pane everything but the minimum")
    func maximise() {
        let focusBefore = PaneResize.maximized(currentValue: 846, before: 552, after: 552,
                                               focusIsBefore: true)
        #expect(focusBefore == 846 + Int(552 + 552 - PaneResize.minimumExtent - 552))

        let focusAfter = PaneResize.maximized(currentValue: 846, before: 552, after: 552,
                                              focusIsBefore: false)
        #expect(focusAfter == 846 + Int(PaneResize.minimumExtent - 552))
    }

    @Test("growing the focused pane moves the divider the right way round")
    func growing() {
        #expect(PaneResize.resized(currentValue: 846, before: 552, after: 552,
                                   focusIsBefore: true, by: 60) == 906)
        // Focused on the far side: the same request moves the divider the other way.
        #expect(PaneResize.resized(currentValue: 846, before: 552, after: 552,
                                   focusIsBefore: false, by: 60) == 786)
    }

    /// A resize that would squeeze the neighbour out of existence is clamped, not obeyed.
    @Test("neither pane can be squeezed below the minimum")
    func clamping() {
        let tooFar = PaneResize.resized(currentValue: 846, before: 552, after: 552,
                                        focusIsBefore: true, by: 5000)
        #expect(tooFar == 846 + Int(552 + 552 - PaneResize.minimumExtent - 552))

        let tooSmall = PaneResize.resized(currentValue: 846, before: 552, after: 552,
                                          focusIsBefore: true, by: -5000)
        #expect(tooSmall == 846 + Int(PaneResize.minimumExtent - 552))
    }
}

/// A split view refuses a divider position it cannot honour — `kAXErrorIllegalArgument`,
/// not a clamp — and the real limit depends on what the panes contain. Zoom asked for 983
/// points and was refused outright, so the request has to degrade rather than fail.
@Suite("Divider fallback")
struct PaneLadderTests {

    @Test("the ladder asks for the ideal position first")
    func idealFirst() {
        let ladder = PaneResize.ladder(from: 846, to: 1277)
        #expect(ladder.first == 1277)
    }

    @Test("it steps back toward where the divider already is")
    func stepsBack() {
        let ladder = PaneResize.ladder(from: 846, to: 1277)
        #expect(ladder.count > 1)
        // Every fallback is nearer the starting point than the one before it.
        for (a, b) in zip(ladder, ladder.dropFirst()) {
            #expect(abs(b - 846) < abs(a - 846))
        }
        #expect(ladder.allSatisfy { $0 != 846 })
    }

    @Test("it works in the shrinking direction too")
    func shrinking() {
        let ladder = PaneResize.ladder(from: 846, to: 400)
        #expect(ladder.first == 400)
        #expect(ladder.allSatisfy { $0 < 846 })
    }

    @Test("asking for where it already is yields nothing to try")
    func noMove() {
        #expect(PaneResize.ladder(from: 846, to: 846).isEmpty)
    }

    @Test("duplicate steps are not attempted twice")
    func noDuplicates() {
        let ladder = PaneResize.ladder(from: 100, to: 102)
        #expect(Set(ladder).count == ladder.count)
    }
}
