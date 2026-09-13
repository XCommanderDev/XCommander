import Testing
@testable import AutographeCore

/// One line out of a documentation comment, for an outline row.
///
/// Most of these are about *not* showing too much: the failure that matters is a summary that
/// runs past the panel or stops in the middle of a version number.
@Suite("Doc summary")
struct DocSummaryTests {

    @Test("markers come off and one sentence comes out")
    func plain() {
        #expect(DocSummary.firstSentence(of: "/// Presses a menu item. The rest is detail.")
                == "Presses a menu item.")
    }

    @Test("a summary paragraph stops at the blank line that ends it")
    func stopsAtBlankLine() {
        let doc = """
        /// The modal state machine: idle, or partway through a sequence
        ///
        /// Everything below here is the long explanation nobody wants on one row.
        """
        #expect(DocSummary.firstSentence(of: doc)
                == "The modal state machine: idle, or partway through a sequence")
    }

    @Test("a summary wrapped over two lines is joined")
    func joinsWrappedLines() {
        let doc = """
        /// Whether the tap should eat this key
        /// rather than pass it to Xcode.
        """
        #expect(DocSummary.firstSentence(of: doc)
                == "Whether the tap should eat this key rather than pass it to Xcode.")
    }

    @Test("a decimal does not end the sentence")
    func decimals() {
        #expect(DocSummary.firstSentence(of: "/// Defaults to 0.35 seconds, by feel.")
                == "Defaults to 0.35 seconds, by feel.")
    }

    @Test("a dotted identifier does not end the sentence")
    func dottedIdentifier() {
        #expect(DocSummary.firstSentence(of: "/// Calls NSApp.shared.terminate when chosen.")
                == "Calls NSApp.shared.terminate when chosen.")
    }

    @Test("an abbreviation does not end the sentence")
    func abbreviation() {
        #expect(DocSummary.firstSentence(of: "/// Some keys, e.g. Return, produce no character. More.")
                == "Some keys, e.g. Return, produce no character.")
    }

    @Test("structured sections are never the summary")
    func stopsAtParameters() {
        let doc = """
        /// Ranks items against a query.
        /// - Parameters:
        ///   - query: what was typed
        """
        #expect(DocSummary.firstSentence(of: doc) == "Ranks items against a query.")
    }

    @Test("a doc that opens with a section has no summary at all")
    func onlySections() {
        #expect(DocSummary.firstSentence(of: "/// - Returns: whether it worked") == nil)
    }

    @Test("inline markup is stripped rather than shown raw")
    func markup() {
        #expect(DocSummary.firstSentence(of: "/// The **leader** is a `KeyEvent` chord.")
                == "The leader is a KeyEvent chord.")
        #expect(DocSummary.firstSentence(of: "/// See [the appendix](C-tcc.md) for why.")
                == "See the appendix for why.")
        #expect(DocSummary.firstSentence(of: "/// What the user sees *before* macOS asks.")
                == "What the user sees before macOS asks.")
        // But an asterisk standing alone is arithmetic, not emphasis.
        #expect(DocSummary.firstSentence(of: "/// Scales by w * h for the panel.")
                == "Scales by w * h for the panel.")
    }

    @Test("block comments are handled, not just triple slashes")
    func blockComment() {
        let doc = """
        /**
         * Opens the picker.
         */
        """
        #expect(DocSummary.firstSentence(of: doc) == "Opens the picker.")
    }

    @Test("nothing worth showing returns nothing", arguments: ["", "///", "/// ", "//\n//"])
    func empty(raw: String) {
        #expect(DocSummary.firstSentence(of: raw) == nil)
    }
}
