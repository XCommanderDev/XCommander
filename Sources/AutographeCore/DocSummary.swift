import Foundation

/// The first sentence of a declaration's documentation, as an outline row can show it.
///
/// **This is the part no other picker has.** Treesitter gives Neovim a syntactic tree, and a
/// syntactic tree does not know that the four lines above a function are that function's
/// documentation. sourcekitd hands us the range, so an outline row can read
/// `press(_:) — one chord at a time, and what it does to the session` instead of just a name.
///
/// The rules are all about *not* showing too much: one sentence, markers stripped, and nothing
/// at all rather than something unhelpful.
public enum DocSummary {

    /// Reduce a raw documentation comment — markers and all — to one line.
    ///
    /// - Returns: nil when there is nothing worth showing, which is a normal answer. A row
    ///   with no summary is a row that shows its name, not a row with a dangling dash.
    public static func firstSentence(of raw: String) -> String? {
        var lines: [String] = []
        for var line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            line = line.trimmingCharacters(in: .whitespaces)
            // Strip the marker styles Swift documentation actually uses.
            for marker in ["///", "/**", "*/", "//"] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count))
                break
            }
            if line.hasPrefix("*") { line = String(line.dropFirst()) }
            line = line.trimmingCharacters(in: .whitespaces)

            // A documentation block often opens with a summary, then a blank line, then the
            // detail. Stop at the blank: everything after it is the part we are not showing.
            if line.isEmpty { if lines.isEmpty { continue } else { break } }
            // Stop at the structured sections too — "- Parameters:", "- Returns:" — which are
            // never a summary and read as noise on one line.
            if line.hasPrefix("-") || line.hasPrefix("#") { break }
            lines.append(line)
        }

        let joined = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !joined.isEmpty else { return nil }

        // One sentence. A full stop only ends it when what follows looks like a new sentence,
        // so `NSApp.shared` and `0.35` do not cut the line in half.
        var sentence = joined
        if let end = endOfFirstSentence(in: joined) {
            sentence = String(joined[joined.startIndex..<end])
        }
        sentence = strippingMarkup(sentence).trimmingCharacters(in: .whitespaces)
        guard sentence.count > 1 else { return nil }
        return sentence
    }

    /// Abbreviations that end in a stop and do not end a sentence. Short, and only the ones
    /// that actually turn up in API documentation.
    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "cf.", "etc.", "vs.", "al.", "approx.", "Inc.", "Ltd.", "Dr.", "Mr.", "Ms.",
    ]

    private static func endOfFirstSentence(in text: String) -> String.Index? {
        var index = text.startIndex
        while let stop = text[index...].firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" }) {
            let after = text.index(after: stop)
            guard after < text.endIndex else { return after }

            // "0.35" and "NSApp.shared": a stop with a non-space after it is inside a token.
            guard text[after] == " " else {
                index = after
                continue
            }
            // "e.g. " — the word *ending* at the stop decides, not the one after it.
            let wordStart = text[text.startIndex..<after].lastIndex(of: " ")
                .map { text.index(after: $0) } ?? text.startIndex
            let word = String(text[wordStart..<after])
            if abbreviations.contains(word) || isInitialism(word) {
                index = after
                continue
            }
            return after
        }
        return nil
    }

    /// `e.g.`, `a.k.a.` — single letters joined by stops, whatever the letters are.
    private static func isInitialism(_ word: String) -> Bool {
        guard word.hasSuffix("."), word.count >= 4 else { return false }
        let parts = word.dropLast().split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { $0.count == 1 }
    }

    /// Inline markup a one-line summary does not need: backticks, emphasis, and link syntax.
    private static func strippingMarkup(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: "**", with: "")
        // Single-asterisk emphasis, but only where it hugs a word: `a * b` is arithmetic.
        var emphasised = ""
        let characters = Array(out)
        for (i, c) in characters.enumerated() {
            guard c == "*" else { emphasised.append(c); continue }
            let before = i > 0 ? characters[i - 1] : " "
            let after = i + 1 < characters.count ? characters[i + 1] : " "
            if before == " " && after == " " { emphasised.append(c) }
        }
        out = emphasised
        while let open = out.firstIndex(of: "["),
              let close = out[open...].firstIndex(of: "]"),
              out.index(after: close) < out.endIndex, out[out.index(after: close)] == "(" {
            guard let end = out[close...].firstIndex(of: ")") else { break }
            let label = String(out[out.index(after: open)..<close])
            out.replaceSubrange(open...end, with: label)
        }
        return out
    }
}
