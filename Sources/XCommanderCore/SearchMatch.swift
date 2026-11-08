import Foundation

/// One hit from a project-wide search.
public struct SearchMatch: Hashable, Sendable {
    public let path: String
    public let line: Int
    /// The matched line, trimmed of its trailing newline.
    public let text: String
    /// Byte offsets of the match within `text`, for highlighting.
    public let start: Int
    public let end: Int

    public init(path: String, line: Int, text: String, start: Int, end: Int) {
        self.path = path
        self.line = line
        self.text = text
        self.start = start
        self.end = end
    }

    /// `Picker.swift:42` — what the row shows on the right.
    public func location(relativeTo root: String?) -> String {
        let shown = root.map { relativePath(under: $0) } ?? path
        return "\(shown):\(line)"
    }

    public func relativePath(under root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

/// Parses `rg --json`, one line of output at a time.
///
/// The JSON form rather than the text form on purpose: a filename or a matched line can
/// contain a colon, and splitting `file:line:text` on colons gets that wrong in exactly the
/// codebases where it matters most. `rg` also emits one JSON object per line, so this can
/// parse a stream as it arrives instead of waiting for the process to finish.
public enum RipgrepParser {

    /// Returns nil for every line that is not a match: `begin`, `end`, `summary`, and any
    /// blank or malformed line.
    public static func parse(line: String) -> SearchMatch? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "match",
              let payload = object["data"] as? [String: Any],
              let path = (payload["path"] as? [String: Any])?["text"] as? String,
              let number = payload["line_number"] as? Int
        else { return nil }

        // rg reports the whole matched line, newline included.
        var text = (payload["lines"] as? [String: Any])?["text"] as? String ?? ""
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }

        let submatch = (payload["submatches"] as? [[String: Any]])?.first
        let start = submatch?["start"] as? Int ?? 0
        let end = submatch?["end"] as? Int ?? 0
        return SearchMatch(path: path, line: number, text: text, start: start, end: end)
    }

    /// Parse a whole chunk of output. Safe to call on partial input: incomplete trailing
    /// lines simply do not parse and are skipped.
    public static func parse(chunk: String) -> [SearchMatch] {
        chunk.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parse(line: String($0)) }
    }
}
