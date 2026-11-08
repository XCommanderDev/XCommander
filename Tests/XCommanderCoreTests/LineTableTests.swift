import Testing
@testable import XCommanderCore

/// Byte offsets in, lines out. Every case here is one the preview pane meets in a real
/// project, and the two at the end are the ones that silently shift a whole file by a line.
@Suite("Line table")
struct LineTableTests {

    private func table(_ s: String) -> (LineTable, [UInt8]) {
        let bytes = Array(s.utf8)
        return (LineTable(bytes: bytes), bytes)
    }

    @Test("a file ending in a newline has no phantom last line")
    func noPhantomLine() {
        let (t, _) = table("a\nb\n")
        #expect(t.lineCount == 2)
    }

    @Test("a file not ending in a newline keeps its last line")
    func noTrailingNewline() {
        let (t, _) = table("a\nb")
        #expect(t.lineCount == 2)
    }

    @Test("an empty file has no lines and does not crash anything downstream")
    func empty() {
        let (t, bytes) = table("")
        #expect(t.lineCount == 0)
        #expect(t.byteRange(ofLine: 1, in: bytes) == nil)
        #expect(t.line(atByteOffset: 0) == 1)
    }

    @Test("CRLF does not leave a carriage return on the drawn line")
    func crlf() {
        let (t, bytes) = table("one\r\ntwo\r\n")
        #expect(t.lineCount == 2)
        #expect(t.text(ofLines: 1...2, in: bytes) == ["one", "two"])
    }

    @Test("byte offsets map to the line that contains them")
    func offsets() {
        //           0123 4567 89
        let (t, _) = table("abc\ndef\ngh")
        #expect(t.line(atByteOffset: 0) == 1)
        #expect(t.line(atByteOffset: 2) == 1)
        #expect(t.line(atByteOffset: 4) == 2)
        #expect(t.line(atByteOffset: 6) == 2)
        #expect(t.line(atByteOffset: 8) == 3)
    }

    @Test("an offset past the end clamps to the last line rather than returning nothing")
    func offsetPastEnd() {
        let (t, _) = table("abc\ndef")
        #expect(t.line(atByteOffset: 9_999) == 2)
    }

    @Test("multi-byte characters do not shift the lines after them")
    func multiByte() {
        // "é" is two UTF-8 bytes and "🖋" is four: counting Characters instead of bytes
        // would put every token on line 2 one glyph to the left.
        let (t, bytes) = table("let café = \"🖋\"\nlet x = 1\n")
        #expect(t.lineCount == 2)
        #expect(t.text(ofLines: 2...2, in: bytes) == ["let x = 1"])
        let secondLineStart = t.lineStarts[1]
        #expect(t.line(atByteOffset: secondLineStart) == 2)
        #expect(t.line(atByteOffset: secondLineStart - 1) == 1)
    }

    @Test("blank lines are lines")
    func blankLines() {
        let (t, bytes) = table("a\n\n\nb\n")
        #expect(t.lineCount == 4)
        #expect(t.text(ofLines: 1...4, in: bytes) == ["a", "", "", "b"])
    }
}
