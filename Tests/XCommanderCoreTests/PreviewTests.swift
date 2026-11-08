import Testing
@testable import XCommanderCore

/// The preview pane's logic, none of which needs a window.
///
/// `PreviewWindow.around` gets the weight here because it is the one piece that can be wrong
/// without looking wrong: a pane that is one line off still looks like a pane.
@Suite("Preview")
struct PreviewTests {

    // MARK: - the window arithmetic

    @Test("no focus line starts at the top")
    func noFocus() {
        let w = PreviewWindow.around(line: nil, total: 500, capacity: 20)
        #expect(w.firstLine == 1)
        #expect(w.count == 20)
    }

    @Test("a short file shows whole, and the window shrinks to it")
    func shortFile() {
        let w = PreviewWindow.around(line: 3, total: 5, capacity: 20)
        #expect(w.firstLine == 1)
        #expect(w.count == 5)
        #expect(w.lastLine == 5)
    }

    @Test("near the top it does not scroll above line 1")
    func clampsAtTop() {
        let w = PreviewWindow.around(line: 2, total: 500, capacity: 20)
        #expect(w.firstLine == 1)
        #expect(w.count == 20)
    }

    @Test("near the end it still shows a full window, not a half-empty one")
    func clampsAtBottom() {
        let w = PreviewWindow.around(line: 499, total: 500, capacity: 20)
        #expect(w.count == 20)
        #expect(w.lastLine == 500)
        #expect(w.firstLine == 481)
    }

    @Test("the focus sits above centre, so the doc comment above a declaration is visible")
    func biasedAboveCentre() {
        let w = PreviewWindow.around(line: 100, total: 500, capacity: 21)
        let above = 100 - w.firstLine
        let below = w.lastLine! - 100
        #expect(above < below)
        #expect(above == 6)
    }

    @Test("the focus is always inside the window it produced", arguments: [
        (1, 1), (1, 500), (250, 500), (500, 500), (17, 20), (20, 20),
    ])
    func focusIsAlwaysShown(line: Int, total: Int) {
        let w = PreviewWindow.around(line: line, total: total, capacity: 20)
        #expect(w.firstLine <= line)
        #expect(line <= w.lastLine!)
    }

    @Test("degenerate inputs produce an empty window rather than a crash", arguments: [
        (0, 20), (500, 0), (0, 0), (10, -1),
    ])
    func degenerate(total: Int, capacity: Int) {
        let w = PreviewWindow.around(line: 5, total: total, capacity: capacity)
        #expect(w.count == 0)
        #expect(w.lastLine == nil)
    }

    @Test("a focus line outside the file is clamped into it")
    func focusOutOfRange() {
        #expect(PreviewWindow.around(line: 9_000, total: 10, capacity: 5).lastLine == 10)
        #expect(PreviewWindow.around(line: -4, total: 10, capacity: 5).firstLine == 1)
    }

    // MARK: - which rows want a preview at all

    @Test("a search hit and a symbol want text at the line they name")
    func requestsFromLocations() {
        let hit = PickerItem(id: "match:/tmp/a.swift:42", title: "a")
        #expect(PreviewRequest.of(hit, style: .text) == .text(path: "/tmp/a.swift", focusLine: 42))

        let symbol = PickerItem(id: "symbol:/tmp/a.swift:7", title: "b")
        #expect(PreviewRequest.of(symbol, style: .text) == .text(path: "/tmp/a.swift", focusLine: 7))
    }

    @Test("a file wants its outline, and carries no line to focus")
    func requestFromFile() {
        let file = PickerItem(id: "file:/tmp/a.swift", title: "a.swift")
        #expect(PreviewRequest.of(file, style: .outline) == .outline(path: "/tmp/a.swift"))
    }

    @Test("rows that are their own answer ask for nothing")
    func noRequest() {
        // A command, a menu path, and an editor tab addressed by coordinates: none is a file.
        #expect(PreviewRequest.of(PickerItem(id: "make.build", title: "b"), style: .text) == nil)
        #expect(PreviewRequest.of(PickerItem(id: PickerTarget.menuID(["Product", "Build"]),
                                             title: "b"), style: .text) == nil)
        #expect(PreviewRequest.of(PickerItem(id: PickerTarget.tabID(pane: 0, index: 1),
                                             title: "b"), style: .outline) == nil)
        // And a style of .none overrides a row that would otherwise qualify.
        #expect(PreviewRequest.of(PickerItem(id: "file:/tmp/a.swift", title: "a"), style: .none) == nil)
    }

    @Test("only the picker whose rows are locations gets a pane")
    func onlySearchPreviews() {
        // A search hit is one line torn out of a file and the surrounding lines are the
        // decision. Every other row is already its own answer, and a pane beside it is
        // furniture.
        #expect(PickerKind.projectSearch.previewStyle == .text)
        for kind in PickerKind.allCases where kind != .projectSearch {
            #expect(kind.previewStyle == .none, "\(kind.rawValue) should not preview")
        }
    }

    @Test("a search row carries the matched range so the pane can mark it")
    func highlightTravels() {
        let request = PreviewRequest.text(path: "/a.swift", focusLine: 12, highlight: 4..<9)
        guard case .text(let path, let line, let highlight) = request else {
            Issue.record("expected text"); return
        }
        #expect(path == "/a.swift")
        #expect(line == 12)
        #expect(highlight == 4..<9)
    }

    // MARK: - the outline

    @Test("flattening keeps document order and records the indent")
    func flatten() {
        let tree = [
            OutlineNode(name: "Session", kind: .struct, line: 10, children: [
                OutlineNode(name: "press", kind: .instanceMethod, line: 12),
                OutlineNode(name: "abandon", kind: .instanceMethod, line: 30),
            ]),
            OutlineNode(name: "Helper", kind: .enum, line: 60),
        ]
        let flat = OutlineNode.flatten(tree)
        #expect(flat.map(\.node.name) == ["Session", "press", "abandon", "Helper"])
        #expect(flat.map(\.depth) == [0, 1, 1, 0])
    }

    @Test("outline badges are the ones the picker list already uses")
    func badgesMatchTheList() {
        // The pane must read as part of the same window, not a transplant.
        #expect(OutlineNode(name: "S", kind: .struct, line: 1).icon == RowIcon.symbol(.struct))
    }

    @Test("an unavailable preview always has something to say")
    func reasonsSpeak() {
        let reasons: [PreviewUnavailable] = [
            .loading, .tooLarge(bytes: 4_000_000), .binary, .unreadable,
            .noOutline, .ambiguous(candidates: 3),
        ]
        for reason in reasons {
            #expect(!reason.message.isEmpty)
        }
        #expect(PreviewUnavailable.ambiguous(candidates: 3).message.contains("3"))
        // A size that integer division would have printed as "1 MB".
        #expect(PreviewUnavailable.tooLarge(bytes: 1_900_000).message.contains("1.9"))
    }
}

/// Slicing a parsed file down to what the pane draws, and the three offset conversions that
/// have to agree for a colour to land on the right glyph.
@Suite("Preview builder")
struct PreviewBuilderTests {

    private let source = """
    import Foundation
    struct A {
        let x = 1
        func go() {}
    }
    // trailing
    """

    private func parts(_ text: String? = nil) -> (LineTable, [UInt8]) {
        let bytes = Array((text ?? source).utf8)
        return (LineTable(bytes: bytes), bytes)
    }

    @Test("a window smaller than the file reports that the file continues")
    func hasMore() {
        let (lines, bytes) = parts()
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [],
                                    focusLine: 1, capacity: 3)
        #expect(p.lines.count == 3)
        #expect(p.hasMore)
    }

    @Test("a window bigger than the file does not claim there is more")
    func noMore() {
        let (lines, bytes) = parts()
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [],
                                    focusLine: nil, capacity: 50)
        #expect(p.lines.count == 6)
        #expect(!p.hasMore)
        #expect(p.lines.map(\.number) == [1, 2, 3, 4, 5, 6])
    }

    @Test("only tokens on drawn lines survive the cut")
    func tokensClipped() {
        let (lines, bytes) = parts()
        let first = SyntaxToken(role: .keyword, offset: 0, length: 6)
        let last = SyntaxToken(role: .comment, offset: lines.lineStarts[5], length: 3)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [first, last],
                                    focusLine: 1, capacity: 2)
        #expect(p.lines.flatMap(\.spans).map(\.role) == [.keyword])
    }

    @Test("a span lands on the characters the token covered")
    func spanPlacement() {
        let (lines, bytes) = parts()
        // "import" on line 1.
        let token = SyntaxToken(role: .keyword, offset: 0, length: 6)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [token],
                                    focusLine: 1, capacity: 1)
        let span = p.lines[0].spans[0]
        let text = p.lines[0].text
        let start = text.index(text.startIndex, offsetBy: span.start)
        let end = text.index(start, offsetBy: span.length)
        #expect(String(text[start..<end]) == "import")
    }

    @Test("tabs are expanded, and spans after them still land correctly")
    func tabsShiftSpans() {
        // A tab, then `let`: the keyword starts at byte 1 but at column 4 once expanded.
        let (lines, bytes) = parts("\tlet x = 1\n")
        let token = SyntaxToken(role: .keyword, offset: 1, length: 3)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [token],
                                    focusLine: 1, capacity: 1)
        let line = p.lines[0]
        #expect(line.text == "    let x = 1")
        let span = line.spans[0]
        #expect(span.start == 4)
        let start = line.text.index(line.text.startIndex, offsetBy: span.start)
        let end = line.text.index(start, offsetBy: span.length)
        #expect(String(line.text[start..<end]) == "let")
    }

    @Test("a multi-byte character does not shift the span that follows it")
    func multiByteShiftsSpans() {
        // "// é" is 6 bytes but 5 UTF-16 units; `let` starts at byte 6, column 5.
        let (lines, bytes) = parts("// é\nlet y = 2\n")
        let token = SyntaxToken(role: .keyword, offset: lines.lineStarts[1], length: 3)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [token],
                                    focusLine: 2, capacity: 2)
        let line = p.lines.first { $0.number == 2 }!
        let span = line.spans[0]
        let start = line.text.index(line.text.startIndex, offsetBy: span.start)
        let end = line.text.index(start, offsetBy: span.length)
        #expect(String(line.text[start..<end]) == "let")
    }

    @Test("an emoji in the line does not shift the span that follows it")
    func emojiShiftsSpans() {
        // An emoji is 4 UTF-8 bytes and 2 UTF-16 units: the two counts disagree, which is
        // exactly the case that puts a colour on the wrong glyph.
        let (lines, bytes) = parts("let a = \"🖋\" ; let b = 2\n")
        let raw = Array("let a = \"🖋\" ; ".utf8).count
        let token = SyntaxToken(role: .keyword, offset: raw, length: 3)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [token],
                                    focusLine: 1, capacity: 1)
        let line = p.lines[0]
        let span = line.spans[0]
        // Indexed through UTF-16, because that is what a span is and what `NSRange` counts.
        // Counting Characters here would land one short: the emoji is one Character and two
        // UTF-16 units, which is the whole reason this conversion happens in Core.
        #expect(utf16Slice(line.text, span) == "let")
    }

    /// The substring a span actually selects when `NSAttributedString` applies it.
    private func utf16Slice(_ text: String, _ span: PreviewSpan) -> String? {
        let units = Array(text.utf16)
        guard span.start + span.length <= units.count else { return nil }
        return String(utf16CodeUnits: Array(units[span.start..<(span.start + span.length)]),
                      count: span.length)
    }

    @Test("the matched text is marked, on the matched line only")
    func highlightPlacement() {
        let (lines, bytes) = parts("let a = 1\nlet needle = 2\nlet needle = 3\n")
        // Byte offsets of "needle" within line 2, which is what SearchMatch records.
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [],
                                    focusLine: 2, capacity: 3, highlight: 4..<10)
        let marked = p.lines.first { $0.number == 2 }!
        let mark = marked.highlight!
        #expect(utf16Slice(marked.text, PreviewSpan(role: .plain, start: mark.lowerBound,
                                                    length: mark.count)) == "needle")
        // Line 3 contains the same word and is not the hit.
        #expect(p.lines.first { $0.number == 3 }?.highlight == nil)
    }

    @Test("a tab before the match does not shift the mark off it")
    func highlightAfterTab() {
        let (lines, bytes) = parts("\tlet needle = 2\n")
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [],
                                    focusLine: 1, capacity: 1, highlight: 5..<11)
        let line = p.lines[0]
        let mark = line.highlight!
        #expect(utf16Slice(line.text, PreviewSpan(role: .plain, start: mark.lowerBound,
                                                  length: mark.count)) == "needle")
    }

    @Test("plain tokens are dropped rather than drawn in a colour")
    func plainDropped() {
        let (lines, bytes) = parts()
        let token = SyntaxToken(role: .plain, offset: 0, length: 6)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [token],
                                    focusLine: 1, capacity: 1)
        #expect(p.lines[0].spans.isEmpty)
    }

    @Test("the focus line survives into the result, clamped to the file")
    func focusKept() {
        let (lines, bytes) = parts()
        #expect(PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [],
                                    focusLine: 4, capacity: 3).focusLine == 4)
        #expect(PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [],
                                    focusLine: 900, capacity: 3).focusLine == 6)
    }

    @Test("an empty file produces an empty pane rather than a crash")
    func emptyFile() {
        let lines = LineTable(bytes: [])
        let p = PreviewBuilder.text(lines: lines, bytes: [], tokens: [],
                                    focusLine: 3, capacity: 10)
        #expect(p.lines.isEmpty)
        #expect(!p.hasMore)
    }
}

/// Choosing which declarations survive when the outline is taller than the pane.
@Suite("Outline fitting")
struct OutlineFittingTests {

    /// Two enums with cases, then the type the file is actually named after — the shape that
    /// made a depth-first cut useless.
    private let tree = [
        OutlineNode(name: "SessionOutcome", kind: .enum, line: 4, children: [
            OutlineNode(name: "passThrough", kind: .enumConstant, line: 6),
            OutlineNode(name: "awaiting", kind: .enumConstant, line: 8),
            OutlineNode(name: "fired", kind: .enumConstant, line: 11),
        ]),
        OutlineNode(name: "CancelReason", kind: .enum, line: 22, children: [
            OutlineNode(name: "escape", kind: .enumConstant, line: 23),
            OutlineNode(name: "timedOut", kind: .enumConstant, line: 30),
        ]),
        OutlineNode(name: "KeymapSession", kind: .struct, line: 38, children: [
            OutlineNode(name: "press", kind: .instanceMethod, line: 60),
        ]),
    ]

    @Test("everything fits when there is room, in document order")
    func everything() {
        let fitted = OutlineNode.fitting(tree, capacity: 99)
        #expect(fitted.count == 9)
        #expect(fitted.first?.node.name == "SessionOutcome")
        #expect(fitted.last?.node.name == "press")
    }

    @Test("a tight pane shows every top-level declaration rather than one branch")
    func breadthBeforeDepth() {
        let fitted = OutlineNode.fitting(tree, capacity: 3)
        #expect(fitted.map(\.node.name) == ["SessionOutcome", "CancelReason", "KeymapSession"])
        #expect(fitted.allSatisfy { $0.depth == 0 })
    }

    @Test("room left over nests into the first children, still in document order")
    func nestsWithSpareRoom() {
        let fitted = OutlineNode.fitting(tree, capacity: 5)
        #expect(fitted.map(\.node.name)
                == ["SessionOutcome", "passThrough", "awaiting", "CancelReason", "KeymapSession"])
        #expect(fitted.map(\.depth) == [0, 1, 1, 0, 0])
    }

    @Test("the type the file is named after survives a cut that depth-first would have lost")
    func theWholePoint() {
        // Depth-first would spend all four rows inside the first enum.
        let fitted = OutlineNode.fitting(tree, capacity: 4)
        #expect(fitted.contains { $0.node.name == "KeymapSession" })
    }

    @Test("no room shows nothing rather than crashing")
    func noRoom() {
        #expect(OutlineNode.fitting(tree, capacity: 0).isEmpty)
        #expect(OutlineNode.fitting([], capacity: 10).isEmpty)
    }
}

/// When a pane is shown at all.
@Suite("Preview mode")
struct PreviewModeTests {

    private let panel = 1180.0

    @Test("off never shows one, however much room there is")
    func off() {
        #expect(!PreviewMode.off.showsPreview(inWindowOfWidth: 3000, panelWidth: panel))
    }

    @Test("on always shows one, however little")
    func on() {
        #expect(PreviewMode.on.showsPreview(inWindowOfWidth: 700, panelWidth: panel))
    }

    @Test("auto needs the panel to fit with room to spare")
    func auto() {
        // A narrow Xcode window beside a browser is the case this exists for.
        #expect(!PreviewMode.auto.showsPreview(inWindowOfWidth: 900, panelWidth: panel))
        #expect(!PreviewMode.auto.showsPreview(inWindowOfWidth: panel + 79, panelWidth: panel))
        #expect(PreviewMode.auto.showsPreview(inWindowOfWidth: panel + 80, panelWidth: panel))
        #expect(PreviewMode.auto.showsPreview(inWindowOfWidth: 1800, panelWidth: panel))
    }

    @Test("the default is the one that cannot embarrass itself")
    func theDefault() {
        #expect(PreviewMode.default == .auto)
        #expect(PreviewMode.auto.note == nil)
    }

    @Test("every mode reads as an answer to a question in a settings window")
    func titles() {
        for mode in PreviewMode.allCases { #expect(!mode.title.isEmpty) }
    }
}

/// What the pane shows for a request — the decision the app and the render tool share.
@Suite("Preview body")
struct PreviewBodyTests {

    private func source(_ text: String, outline: [OutlineNode], isSource: Bool) -> PreviewBuilder.Source {
        let bytes = Array(text.utf8)
        return PreviewBuilder.Source(lines: LineTable(bytes: bytes), bytes: bytes,
                                     tokens: [], outline: outline, isSource: isSource)
    }

    @Test("a file with declarations shows them")
    func outlineWins() {
        let s = source("struct A {}", outline: [OutlineNode(name: "A", kind: .struct, line: 1)],
                       isSource: true)
        guard case .success(.outline(let nodes)) =
            PreviewBuilder.body(for: .outline(path: "/a.swift"), from: s, capacity: 10) else {
            Issue.record("expected an outline"); return
        }
        #expect(nodes.count == 1)
    }

    @Test("a file that cannot have declarations shows its opening lines instead of refusing")
    func markdownFallsBackToText() {
        // "no declarations" is true of a README and useless; its first lines answer the same
        // question the outline was asked.
        let s = source("# Title\nSome prose.\n", outline: [], isSource: false)
        guard case .success(.text(let text)) =
            PreviewBuilder.body(for: .outline(path: "/a.md"), from: s, capacity: 10) else {
            Issue.record("expected a text fallback"); return
        }
        #expect(text.lines.first?.text == "# Title")
        #expect(text.focusLine == nil)
    }

    @Test("a source file that genuinely declares nothing says so")
    func emptySwiftSaysSo() {
        let s = source("// just a comment\n", outline: [], isSource: true)
        guard case .failure(let reason) =
            PreviewBuilder.body(for: .outline(path: "/a.swift"), from: s, capacity: 10) else {
            Issue.record("expected a reason"); return
        }
        #expect(reason == .noOutline)
    }

    @Test("a text request always shows text, whatever the file declares")
    func textRequest() {
        let s = source("let a = 1\nlet b = 2\n",
                       outline: [OutlineNode(name: "a", kind: .variable, line: 1)], isSource: true)
        guard case .success(.text(let text)) =
            PreviewBuilder.body(for: .text(path: "/a.swift", focusLine: 2), from: s, capacity: 10) else {
            Issue.record("expected text"); return
        }
        #expect(text.focusLine == 2)
    }
}

/// Bringing a match into view when it sits further right than the pane is wide.
///
/// Without this the pane highlights a line that appears not to contain what was searched for:
/// the line truncates at the right edge and the mark is past it. That is the pane failing at
/// the one thing it exists for.
@Suite("Preview elision")
struct PreviewElisionTests {

    private func line(_ text: String, mark: Range<Int>) -> PreviewLine {
        PreviewLine(number: 1, text: text, spans: [], highlight: mark)
    }

    @Test("a match that already fits is left alone")
    func fits() {
        let l = line("let needle = 1", mark: 4..<10)
        #expect(l.eliding(toShow: 4..<10, columns: 80).text == "let needle = 1")
    }

    @Test("a far match is brought into view, and the line still starts where it did")
    func elides() {
        let text = "menuBar.apply(Status.derive(" + String(repeating: "x", count: 90) + "needle))"
        let mark = 118..<124
        let out = line(text, mark: mark).eliding(toShow: mark, columns: 80)
        // The head is kept, so you can still see what the line is.
        #expect(out.text.hasPrefix("menuBar.apply(Status"))
        #expect(out.text.contains("…"))
        // And the match is visible, well inside the pane.
        let mk = out.highlight!
        #expect(mk.upperBound <= 80)
        #expect(utf16Slice(out.text, PreviewSpan(role: .plain, start: mk.lowerBound,
                                                 length: mk.count)) == "needle")
    }

    @Test("context immediately before the match survives the cut")
    func keepsContextBeforeMatch() {
        let text = String(repeating: "a", count: 100) + "KEY: needle"
        let mark = 105..<111
        let out = line(text, mark: mark).eliding(toShow: mark, columns: 80)
        #expect(out.text.contains("KEY: needle"))
    }

    @Test("only the matched line is touched, so the pane keeps its context")
    func othersUntouched() {
        // The bug this replaced scrolled every line, and the short neighbours scrolled to
        // nothing — one useful line and a column of blanks.
        let long = String(repeating: "z", count: 120) + "needle"
        let bytes = Array((long + "\nshort line\n").utf8)
        let lines = LineTable(bytes: bytes)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [],
                                    focusLine: 1, capacity: 4,
                                    highlight: 120..<126, columns: 80)
        #expect(p.lines[1].text == "short line")
    }

    @Test("a span straddling the cut is dropped rather than drawn in the wrong place")
    func straddlingSpanDropped() {
        let text = String(repeating: "b", count: 100) + "let needle = 1"
        let mark = 104..<110
        let l = PreviewLine(number: 1, text: text,
                            spans: [PreviewSpan(role: .keyword, start: 20, length: 60)],
                            highlight: mark)
        let out = l.eliding(toShow: mark, columns: 80)
        // It covered both sides of the cut; colouring part of it would be a lie.
        #expect(out.spans.isEmpty)
    }

    @Test("indentation does not eat the head, so an indented line shows as much code")
    func indentIsFree() {
        let code = "menuBar.apply(XCommanderStatus.derive(" + String(repeating: "x", count: 90) + "needle))"
        let mark = 128..<134
        let flat = line(code, mark: mark).eliding(toShow: mark, columns: 80)
        // The same line, indented by eight: the head slides right with the indent instead of
        // being consumed by it, so the visible code is the same.
        let indented = line("        " + code, mark: 8 + mark.lowerBound..<(8 + mark.upperBound))
            .eliding(toShow: 8 + mark.lowerBound..<(8 + mark.upperBound), columns: 80)
        #expect(indented.text == "        " + String(flat.text.prefix(flat.text.count)))
    }

    @Test("a very deep indent does not spend the whole pane on whitespace")
    func deepIndentIsCapped() {
        let deep = String(repeating: " ", count: 60)
        let code = deep + "call(" + String(repeating: "y", count: 90) + "needle)"
        let mark = 155..<161
        let out = line(code, mark: mark).eliding(toShow: mark, columns: 80)
        // Capped at columns / 5 = 16, so the ellipsis arrives well before the pane's edge.
        let ellipsisAt = Array(out.text).firstIndex(of: "…") ?? 0
        #expect(ellipsisAt <= 40)
    }

    @Test("a match inside the head is not elided at all")
    func matchInHead() {
        let text = "let needle = " + String(repeating: "c", count: 200)
        let mark = 4..<10
        #expect(l1(text, mark).eliding(toShow: mark, columns: 80).text == text)
    }

    private func l1(_ t: String, _ m: Range<Int>) -> PreviewLine {
        PreviewLine(number: 1, text: t, spans: [], highlight: m)
    }

    private func utf16Slice(_ text: String, _ span: PreviewSpan) -> String? {
        let units = Array(text.utf16)
        guard span.start + span.length <= units.count else { return nil }
        return String(utf16CodeUnits: Array(units[span.start..<(span.start + span.length)]),
                      count: span.length)
    }
}
