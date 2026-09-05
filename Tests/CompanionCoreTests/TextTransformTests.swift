import Testing
@testable import CompanionCore

/// The text features Xcode does not have. Every case is a hand-written before/after pair,
/// which is the only way to be sure about whitespace.
@Suite("Text transforms")
struct TextTransformTests {

    @Test("sort sorts by trimmed content, so indentation does not decide the order")
    func sortLines() {
        let input = "    charlie\n  alpha\n      bravo"
        #expect(TextTransform.sortLines.apply(to: input) == "  alpha\n      bravo\n    charlie")
    }

    @Test("reverse and reverse-sort")
    func reversing() {
        #expect(TextTransform.reverseLines.apply(to: "a\nb\nc") == "c\nb\na")
        #expect(TextTransform.sortLinesReversed.apply(to: "a\nc\nb") == "c\nb\na")
    }

    @Test("join collapses lines and their indentation into one line")
    func joinLines() {
        let input = "let greeting =\n    \"hello\"\n    + name"
        #expect(TextTransform.joinLines.apply(to: input) == "let greeting = \"hello\" + name")
    }

    @Test("join drops blank lines rather than leaving double spaces")
    func joinSkipsBlanks() {
        #expect(TextTransform.joinLines.apply(to: "one\n\ntwo") == "one two")
    }

    @Test("duplicates are removed, first occurrence kept")
    func dedupe() {
        #expect(TextTransform.removeDuplicateLines.apply(to: "a\nb\na\nc\nb") == "a\nb\nc")
    }

    @Test("trailing whitespace goes, leading stays")
    func trim() {
        #expect(TextTransform.trimTrailingWhitespace.apply(to: "  a   \n\tb\t") == "  a\n\tb")
    }

    /// The flagship: Emacs has `align-regexp`, vim has easy-align, Xcode has nothing.
    @Test("align lines up an assignment block on the equals sign")
    func alignOnEquals() {
        let input = """
        let x = 1
        let yy = 22
        let zzz = 333
        """
        let expected = """
        let x   = 1
        let yy  = 22
        let zzz = 333
        """
        #expect(TextTransform.align.apply(to: input) == expected)
    }

    @Test("align picks the colon when there is no equals sign")
    func alignOnColon() {
        let input = "a: 1\nbbb: 2"
        #expect(TextTransform.align.apply(to: input) == "a   : 1\nbbb : 2")
    }

    /// A delimiter on only one line is not a column, and shoving that line around would be
    /// worse than leaving it alone.
    @Test("align leaves lines without the delimiter untouched")
    func alignLeavesOthersAlone() {
        let input = "let x = 1\n// a comment\nlet yy = 2"
        let out = TextTransform.align.apply(to: input)
        #expect(out.components(separatedBy: "\n")[1] == "// a comment")
    }

    @Test("align on text with no delimiter at all changes nothing")
    func alignNoOp() {
        let input = "just\nsome\nwords"
        #expect(TextTransform.align.apply(to: input) == input)
    }

    @Test("case conversions round-trip")
    func caseConversion() {
        #expect(TextTransform.camelCase.apply(to: "some_identifier_here") == "someIdentifierHere")
        #expect(TextTransform.snakeCase.apply(to: "someIdentifierHere") == "some_identifier_here")
        #expect(TextTransform.upperCase.apply(to: "abc") == "ABC")
        #expect(TextTransform.lowerCase.apply(to: "ABC") == "abc")
    }

    @Test("a single line is a valid selection for every transform")
    func singleLine() {
        for transform in TextTransform.allCases {
            let out = transform.apply(to: "let x = 1")
            #expect(!out.isEmpty, "\(transform) emptied a single line")
        }
    }
}

/// A linewise selection carries its trailing newline — vim's `V` does, and so does
/// dragging across whole lines. These tests exist because sorting such a selection put a
/// blank line at the top and welded the block to the line below it, in a real editor.
@Suite("Transforms on linewise selections")
struct LinewiseSelectionTests {

    @Test("sorting a selection that ends in a newline keeps the newline at the end")
    func sortKeepsTrailingNewline() {
        #expect(TextTransform.sortLines.apply(to: "c\na\nb\n") == "a\nb\nc\n")
    }

    @Test("no transform moves an empty trailing component to the front")
    func noLeadingBlankLine() {
        for transform in [TextTransform.sortLines, .sortLinesReversed, .reverseLines,
                          .removeDuplicateLines, .trimTrailingWhitespace, .align] {
            let out = transform.apply(to: "let bb = 2\nlet a = 1\n")
            #expect(!out.hasPrefix("\n"), "\(transform) produced a leading blank line")
            #expect(out.hasSuffix("\n"), "\(transform) lost the trailing newline")
        }
    }

    @Test("align works on a linewise selection")
    func alignLinewise() {
        let input = "let x = 1\nlet yy = 22\n"
        #expect(TextTransform.align.apply(to: input) == "let x  = 1\nlet yy = 22\n")
    }

    @Test("reverse of a linewise selection reverses the lines, not the newline")
    func reverseLinewise() {
        #expect(TextTransform.reverseLines.apply(to: "a\nb\nc\n") == "c\nb\na\n")
    }

    @Test("join collapses a linewise selection and keeps its newline")
    func joinLinewise() {
        #expect(TextTransform.joinLines.apply(to: "one\ntwo\n") == "one two\n")
    }

    @Test("an empty selection is left alone rather than trapped on")
    func emptySelection() {
        for transform in TextTransform.allCases {
            #expect(transform.apply(to: "") == "")
        }
    }
}
