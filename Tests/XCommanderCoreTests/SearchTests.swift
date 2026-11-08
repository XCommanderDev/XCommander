import Testing
@testable import XCommanderCore

/// Parsed against real `rg --json` output, captured from ripgrep 15.2.0 rather than
/// written from memory.
@Suite("Ripgrep parsing")
struct RipgrepParserTests {

    private let matchLine = #"{"type":"match","data":{"path":{"text":"Sources/XCommanderCore/Picker.swift"},"lines":{"text":"public struct PickerSession: Sendable {\n"},"line_number":42,"absolute_offset":1435,"submatches":[{"match":{"text":"PickerSession"},"start":14,"end":27}]}}"#

    @Test("a match line yields the path, line number, text and match range")
    func parsesMatch() throws {
        let m = try #require(RipgrepParser.parse(line: matchLine))
        #expect(m.path == "Sources/XCommanderCore/Picker.swift")
        #expect(m.line == 42)
        #expect(m.text == "public struct PickerSession: Sendable {")
        #expect(m.start == 14)
        #expect(m.end == 27)
    }

    /// rg reports the whole line including its newline; a row that renders one is a row
    /// that breaks the list's layout.
    @Test("the trailing newline is stripped")
    func stripsNewline() throws {
        let m = try #require(RipgrepParser.parse(line: matchLine))
        #expect(!m.text.hasSuffix("\n"))
    }

    @Test("begin, end and summary lines are not matches")
    func ignoresNonMatches() {
        let begin = #"{"type":"begin","data":{"path":{"text":"a.swift"}}}"#
        let end = #"{"type":"end","data":{"path":{"text":"a.swift"},"binary_offset":null}}"#
        #expect(RipgrepParser.parse(line: begin) == nil)
        #expect(RipgrepParser.parse(line: end) == nil)
    }

    /// The parser reads a stream, so it will be handed half-written lines.
    @Test("malformed and partial lines are skipped rather than crashing")
    func toleratesGarbage() {
        #expect(RipgrepParser.parse(line: "") == nil)
        #expect(RipgrepParser.parse(line: "not json") == nil)
        #expect(RipgrepParser.parse(line: #"{"type":"match","data":{"#) == nil)
        #expect(RipgrepParser.parse(line: #"{"type":"match","data":{}}"#) == nil)
    }

    @Test("a chunk of output yields only its matches")
    func parsesChunk() {
        let chunk = [
            #"{"type":"begin","data":{"path":{"text":"a.swift"}}}"#,
            matchLine,
            #"{"type":"end","data":{"path":{"text":"a.swift"}}}"#,
        ].joined(separator: "\n")
        #expect(RipgrepParser.parse(chunk: chunk).count == 1)
    }

    /// The reason for using rg's JSON rather than splitting `file:line:text` on colons.
    @Test("a colon in the matched line does not confuse the parser")
    func colonsInContent() throws {
        let line = #"{"type":"match","data":{"path":{"text":"a:b/c.swift"},"lines":{"text":"let x: [String: Int] = [:]\n"},"line_number":7,"submatches":[{"match":{"text":"String"},"start":8,"end":14}]}}"#
        let m = try #require(RipgrepParser.parse(line: line))
        #expect(m.path == "a:b/c.swift")
        #expect(m.line == 7)
        #expect(m.text == "let x: [String: Int] = [:]")
    }

    @Test("paths are shown relative to the project root")
    func relativePaths() {
        let m = SearchMatch(path: "/p/Sources/A.swift", line: 3, text: "x", start: 0, end: 1)
        #expect(m.relativePath(under: "/p") == "Sources/A.swift")
        #expect(m.location(relativeTo: "/p") == "Sources/A.swift:3")
        #expect(m.location(relativeTo: nil) == "/p/Sources/A.swift:3")
        // A path outside the root is left absolute rather than mangled.
        #expect(m.relativePath(under: "/other") == "/p/Sources/A.swift")
    }
}

@Suite("Dynamic pickers")
struct DynamicPickerTests {

    private func search() -> PickerSession {
        PickerSession(title: "Search", items: [], source: .dynamic)
    }

    /// The results already answer the query. Fuzzy-filtering them again would drop every
    /// hit whose match is in the line rather than in the path — which is most of them.
    @Test("a dynamic picker does not filter its rows by the query")
    func doesNotRefilter() {
        var p = search()
        p.replaceRows([
            PickerItem(id: "1", title: "let x = 1", detail: "A.swift:3"),
            PickerItem(id: "2", title: "let y = 2", detail: "B.swift:9"),
        ])
        #expect(p.rows.count == 2)
        for c in "zzz" { _ = p.press(KeyEvent(c)) }
        #expect(p.query == "zzz")
        #expect(p.rows.count == 2, "rows were filtered by a query they already answer")
    }

    @Test("replacing rows clamps the selection")
    func clamping() {
        var p = search()
        p.replaceRows((1...5).map { PickerItem(id: "\($0)", title: "row \($0)") })
        _ = p.press(KeyEvent(.down))
        _ = p.press(KeyEvent(.down))
        #expect(p.selection == 2)
        p.replaceRows([PickerItem(id: "1", title: "row 1")])
        #expect(p.selection == 0)
        #expect(p.selectedItem?.id == "1")
    }

    @Test("navigation and cancelling work the same as in a static picker")
    func sharedBehaviour() {
        var p = search()
        p.replaceRows((1...3).map { PickerItem(id: "\($0)", title: "row \($0)") })
        _ = p.press(KeyEvent("n", [.control]))
        #expect(p.selection == 1)
        #expect(p.press(.escape) == .cancelled)
    }

    @Test("a static picker still filters, so the two sources really do differ")
    func staticStillFilters() {
        var p = PickerSession(title: "Files", items: [
            PickerItem(id: "1", title: "alpha.swift"),
            PickerItem(id: "2", title: "beta.swift"),
        ])
        for c in "alp" { _ = p.press(KeyEvent(c)) }
        #expect(p.rows.count == 1)
    }
}
