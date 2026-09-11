import Foundation

/// The result of matching a query against one candidate.
public struct FuzzyMatch: Hashable, Sendable {
    public let score: Int
    /// Indices into the candidate that the query matched, for highlighting.
    public let matched: [Int]
}

/// Subsequence matching with bonuses, the way every good picker does it.
///
/// The rule that matters: **where a character matches counts for more than how many
/// match.** `gd` should rank `gotoDefinition` above `gedit`, because in the first the `d`
/// lands on a word boundary and in the second it lands mid-word. Everything below is in
/// service of that.
public enum FuzzyMatcher {

    // Scores are small integers chosen so hand-computed expectations stay readable in the
    // tests. Their absolute values mean nothing; only the ordering does.
    static let startOfStringBonus = 14
    static let afterSeparatorBonus = 12
    static let camelBoundaryBonus = 10
    static let consecutiveBonus = 8
    static let exactCaseBonus = 2
    static let gapPenalty = 1
    /// Separators in the things we search: menu paths (`Product > Build`), file paths,
    /// and identifiers.
    static let separators = Set(" >/\\:._-()[]".unicodeScalars.map { Character($0) })

    /// Nil when the query is not a subsequence of the candidate at all.
    ///
    /// An empty query matches everything with score 0, which is what a picker wants on its
    /// first frame: show the list, ranked by its natural order.
    public static func match(query: String, candidate: String) -> FuzzyMatch? {
        if query.isEmpty { return FuzzyMatch(score: 0, matched: []) }
        let q = Array(query)
        let c = Array(candidate)
        guard q.count <= c.count else { return nil }

        // dp[ci] is the best score for the query prefix ending with its last character
        // matched at candidate position ci. Unreachable positions stay nil.
        var previous = [Int?](repeating: nil, count: c.count)
        var current = [Int?](repeating: nil, count: c.count)

        for (qi, qc) in q.enumerated() {
            // `running` is the best score from the previous query character at any earlier
            // position, decayed by one gap penalty per character skipped. Carrying it
            // forward is what keeps this linear instead of quadratic.
            var running: Int? = nil
            var runningWasAdjacent = false

            for ci in c.indices {
                if ci > 0 {
                    let decayed = running.map { $0 - gapPenalty }
                    if let prior = previous[ci - 1], prior >= (decayed ?? Int.min) {
                        running = prior
                        runningWasAdjacent = true
                    } else {
                        running = decayed
                        runningWasAdjacent = false
                    }
                }

                guard matches(qc, c[ci]) else { current[ci] = nil; continue }

                let base: Int
                if qi == 0 {
                    base = 0
                } else if let running {
                    base = running + (runningWasAdjacent ? consecutiveBonus : 0)
                } else {
                    current[ci] = nil
                    continue
                }
                current[ci] = base + positionBonus(c, ci) + (qc == c[ci] ? exactCaseBonus : 0)
            }

            previous = current
            current = [Int?](repeating: nil, count: c.count)
        }

        guard let best = previous.compactMap({ $0 }).max() else { return nil }
        // Shorter candidates win ties: "Build" should beat "Build Documentation" for "build".
        let score = best - c.count / 8
        return FuzzyMatch(score: score, matched: highlightIndices(q, c))
    }

    private static func matches(_ a: Character, _ b: Character) -> Bool {
        a == b || a.lowercased() == b.lowercased()
    }

    private static func positionBonus(_ c: [Character], _ i: Int) -> Int {
        if i == 0 { return startOfStringBonus }
        if separators.contains(c[i - 1]) { return afterSeparatorBonus }
        if c[i - 1].isLowercase && c[i].isUppercase { return camelBoundaryBonus }
        if c[i - 1].isLetter == false && c[i].isLetter { return afterSeparatorBonus }
        return 0
    }

    /// Positions to highlight.
    ///
    /// Deliberately a plain greedy left-to-right walk rather than a backtrack through the
    /// table above. It can differ from the scoring path in contrived cases, and the cost of
    /// being wrong is one bold character in the wrong place — not worth carrying a parent
    /// pointer through the whole matrix for.
    private static func highlightIndices(_ q: [Character], _ c: [Character]) -> [Int] {
        var out: [Int] = []
        var qi = 0
        for (ci, ch) in c.enumerated() where qi < q.count {
            if matches(q[qi], ch) { out.append(ci); qi += 1 }
        }
        return qi == q.count ? out : []
    }

    /// Rank a list, dropping anything the query does not match.
    ///
    /// Ties are broken by the candidate's original position so the ordering is stable and
    /// the list does not shuffle under the cursor as you type.
    public static func rank<T>(_ items: [T], query: String,
                               text: (T) -> String) -> [(item: T, match: FuzzyMatch)] {
        // Spelled out rather than chained: the inference cost of a chained
        // compactMap/sorted/map over tuples defeats the type checker.
        var scored: [(index: Int, item: T, match: FuzzyMatch)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            guard let m = match(query: query, candidate: text(item)) else { continue }
            scored.append((index: index, item: item, match: m))
        }
        scored.sort { a, b in
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            return a.index < b.index
        }
        var out: [(item: T, match: FuzzyMatch)] = []
        out.reserveCapacity(scored.count)
        for s in scored { out.append((item: s.item, match: s.match)) }
        return out
    }
}
