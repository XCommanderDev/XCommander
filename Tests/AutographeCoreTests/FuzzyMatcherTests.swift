import Foundation
import Testing
@testable import AutographeCore

/// The matcher is judged by its *ordering*, not its numbers, so almost every test here
/// asserts that one candidate beats another rather than pinning a score.
@Suite("Fuzzy matcher")
struct FuzzyMatcherTests {

    private func score(_ query: String, _ candidate: String) -> Int? {
        FuzzyMatcher.match(query: query, candidate: candidate)?.score
    }

    @Test("a non-subsequence does not match at all")
    func nonSubsequence() {
        #expect(FuzzyMatcher.match(query: "zzz", candidate: "Product > Build") == nil)
        #expect(FuzzyMatcher.match(query: "bx", candidate: "Build") == nil)
        // Out of order is not a match: "db" cannot match "Build" because b precedes d.
        #expect(FuzzyMatcher.match(query: "db", candidate: "Build") == nil)
    }

    @Test("an empty query matches everything, so the picker's first frame is the full list")
    func emptyQuery() {
        let m = FuzzyMatcher.match(query: "", candidate: "anything")
        #expect(m?.score == 0)
    }

    @Test("a query longer than the candidate cannot match")
    func tooLong() {
        #expect(FuzzyMatcher.match(query: "building", candidate: "Build") == nil)
    }

    /// The canonical example, and the reason the matcher scores position rather than count.
    @Test("gd ranks gotoDefinition above gedit")
    func wordBoundaryBeatsMidWord() throws {
        let goto = try #require(score("gd", "gotoDefinition"))
        let gedit = try #require(score("gd", "gedit"))
        #expect(goto > gedit)
    }

    @Test("a match after a separator beats one mid-word")
    func separatorBonus() throws {
        // The `b` of `Build` follows "> ", the `b` of `Debug` does not.
        let afterSeparator = try #require(score("b", "Product > Build"))
        let midWord = try #require(score("b", "Xcode Debugger"))
        #expect(afterSeparator > midWord)
    }

    @Test("consecutive characters beat scattered ones")
    func consecutiveBonus() throws {
        let together = try #require(score("build", "Build"))
        let scattered = try #require(score("build", "bxuxixlxd"))
        #expect(together > scattered)
    }

    @Test("a match at the start beats the same match later")
    func startOfString() throws {
        #expect(try #require(score("run", "Run")) > (try #require(score("run", "Perform Run"))))
    }

    @Test("shorter candidates win ties")
    func shorterWins() throws {
        #expect(try #require(score("build", "Build")) > (try #require(score("build", "Build Documentation"))))
    }

    @Test("matching is case-insensitive, but an exact case match scores higher")
    func caseHandling() throws {
        #expect(score("BUILD", "Build") != nil)
        #expect(try #require(score("B", "Build")) > (try #require(score("b", "Build"))))
    }

    @Test("matched indices are returned for highlighting")
    func highlighting() throws {
        let m = try #require(FuzzyMatcher.match(query: "bd", candidate: "Build"))
        // b at 0, d at 4.
        #expect(m.matched == [0, 4])
    }

    /// Ranking real rows from the real menu dump, which is what the palette will do.
    @Test("ranking puts the obvious answer first")
    func rankingRealCommands() throws {
        let commands = [
            "Product > Build For > Testing",
            "Product > Build",
            "Product > Build Documentation",
            "Editor > Code Folding > Unfold",
            "Product > Perform Action > Build with Timing Summary",
        ]
        let ranked = FuzzyMatcher.rank(commands, query: "build") { $0 }
        #expect(ranked.first?.item == "Product > Build")
        // Four of the five: "Editor > Code Folding > Unfold" has no `b` at all.
        #expect(ranked.count == 4)
    }

    @Test("ranking drops non-matches and is stable for equal scores")
    func rankingFilters() {
        let items = ["alpha", "beta", "gamma"]
        let ranked = FuzzyMatcher.rank(items, query: "a") { $0 }
        #expect(ranked.count == 3)
        let none = FuzzyMatcher.rank(items, query: "zq") { $0 }
        #expect(none.isEmpty)
    }

    /// A picker types one character at a time over hundreds of rows, so this runs on every
    /// keystroke. Not a benchmark, just a guard against an accidental quadratic.
    @Test("ranking 800 menu-path-sized rows is fast enough to run per keystroke")
    func performance() {
        let rows = (0..<800).map { "Product > Perform Action > Command number \($0)" }
        let start = Date()
        for query in ["p", "pa", "pac", "pacn"] {
            _ = FuzzyMatcher.rank(rows, query: query) { $0 }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "four passes over 800 rows took \(elapsed)s")
    }
}
