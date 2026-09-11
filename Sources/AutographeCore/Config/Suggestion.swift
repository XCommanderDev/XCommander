import Foundation

/// "Did you mean…" for a mistyped command id.
///
/// **Not `FuzzyMatcher`, and the reason is worth stating**, because reaching for the matcher
/// already in the module is the obvious move and it does not work. That matcher answers
/// *"which of these did the user abbreviate?"* — it takes `mkbld` to `make.build` by looking
/// for the query as a subsequence. A typo is a different shape of wrong: `make.buidl` is not a
/// subsequence of `make.build`, because the transposed `l` has nowhere left to match. Every
/// transposition and every extra character fails the same way.
///
/// Edit distance is the tool for "almost the same string", which is the actual question here.
/// Two matchers, two jobs.
enum Suggestion {

    /// The closest candidate, if it is close enough to be worth saying out loud. A wrong
    /// guess is worse than none: it sends someone off to check a command that was never the
    /// one they wanted.
    static func nearest(_ typed: String, in candidates: [String]) -> String? {
        var best: (name: String, distance: Int)?
        for candidate in candidates {
            let d = distance(typed, candidate)
            if best == nil || d < best!.distance { best = (candidate, d) }
        }
        guard let best, best.distance <= max(2, typed.count / 4) else { return nil }
        return best.name
    }

    /// Levenshtein, two rows rather than a full matrix. The registry is a few hundred ids and
    /// this runs once per bad binding, so the interesting property is that it is obvious.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1,        // deletion
                                 current[j - 1] + 1,     // insertion
                                 substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
