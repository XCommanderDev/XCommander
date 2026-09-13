import Testing
@testable import AutographeCore

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

    @Test("every picker has decided what it shows, and the answer matches the question it leaves")
    func everyPickerHasAPolicy() {
        // Rows that are locations want context; rows that name a file want its shape; rows
        // that are the answer want nothing.
        #expect(PickerKind.projectSearch.previewStyle == .text)
        #expect(PickerKind.documentSymbols.previewStyle == .text)
        #expect(PickerKind.files.previewStyle == .outline)
        #expect(PickerKind.buffers.previewStyle == .outline)
        #expect(PickerKind.commands.previewStyle == .none)
        #expect(PickerKind.recentProjects.previewStyle == .none)
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
    }
}

/// Slicing a parsed file down to what the pane draws.
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

    private func parts() -> (LineTable, [UInt8]) {
        let bytes = Array(source.utf8)
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
    }

    @Test("only tokens on drawn lines survive the cut")
    func tokensClipped() {
        let (lines, bytes) = parts()
        // One token on line 1, one on the last line.
        let first = SyntaxToken(role: .keyword, offset: 0, length: 6)
        let lastLineStart = lines.lineStarts[5]
        let last = SyntaxToken(role: .comment, offset: lastLineStart, length: 3)
        let p = PreviewBuilder.text(lines: lines, bytes: bytes, tokens: [first, last],
                                    focusLine: 1, capacity: 2)
        #expect(p.tokens.map(\.role) == [.keyword])
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
