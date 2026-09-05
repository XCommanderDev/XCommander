import Foundation

/// The text operations Xcode does not have.
///
/// Checked against a live Xcode 26.6 menu dump taken with a source editor focused: Xcode
/// *does* have multiple cursors, move line up/down, comment selection, re-indent and
/// reformat-to-width. It has none of these.
///
/// Pure functions over a string, so every one of them is unit-tested against hand-written
/// before/after pairs. The app reads `AXSelectedText`, calls `apply`, and writes it back;
/// Xcode's own undo reverts the result.
public enum TextTransform: Hashable, Sendable, CaseIterable {
    /// Align consecutive lines on their first occurrence of a delimiter, padding with
    /// spaces. Emacs has `align-regexp`, vim has easy-align, Xcode has nothing.
    case align
    /// Collapse the selected lines into one, separated by single spaces.
    case joinLines
    case sortLines
    case sortLinesReversed
    case removeDuplicateLines
    case reverseLines
    case trimTrailingWhitespace
    case upperCase
    case lowerCase
    /// `some_identifier` becomes `someIdentifier`.
    case camelCase
    /// `someIdentifier` becomes `some_identifier`.
    case snakeCase

    public var title: String {
        switch self {
        case .align: "align"
        case .joinLines: "join lines"
        case .sortLines: "sort lines"
        case .sortLinesReversed: "sort lines reversed"
        case .removeDuplicateLines: "remove duplicate lines"
        case .reverseLines: "reverse lines"
        case .trimTrailingWhitespace: "trim trailing whitespace"
        case .upperCase: "upper case"
        case .lowerCase: "lower case"
        case .camelCase: "camelCase"
        case .snakeCase: "snake_case"
        }
    }

    /// Delimiters `align` will line up on, in priority order. The first one that appears on
    /// at least two of the selected lines wins, so aligning a block of `let` declarations
    /// picks `=` without being told.
    static let alignDelimiters = ["=", ":", "->", "//", ","]

    public func apply(to text: String) -> String {
        switch self {
        case .upperCase: return text.uppercased()
        case .lowerCase: return text.lowercased()
        case .camelCase: return Self.camelCased(text)
        case .snakeCase: return Self.snakeCased(text)
        case .joinLines:
            return lines(of: text)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        default:
            return rejoin(transformLines(lines(of: text)), like: text)
        }
    }

    private func transformLines(_ lines: [String]) -> [String] {
        switch self {
        case .sortLines: return lines.sorted { $0.trimmed() < $1.trimmed() }
        case .sortLinesReversed: return lines.sorted { $0.trimmed() > $1.trimmed() }
        case .reverseLines: return lines.reversed()
        case .trimTrailingWhitespace:
            return lines.map { line in
                var line = line
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return line
            }
        case .removeDuplicateLines:
            var seen = Set<String>()
            return lines.filter { seen.insert($0.trimmed()).inserted }
        case .align: return Self.aligned(lines)
        default: return lines
        }
    }

    private func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Preserve a trailing newline if the selection had one: selecting whole lines in an
    /// editor usually includes it, and losing it silently joins the block to the next line.
    private func rejoin(_ lines: [String], like original: String) -> String {
        lines.joined(separator: "\n")
    }

    // MARK: - align

    static func aligned(_ lines: [String]) -> [String] {
        guard let delimiter = alignDelimiters.first(where: { d in
            lines.filter { $0.contains(d) }.count >= 2
        }) else { return lines }

        // Split each line at its *first* delimiter. Lines without one are left alone rather
        // than being shoved around by a rule that does not apply to them.
        var split: [(head: String, tail: String)?] = []
        for line in lines {
            guard let r = line.range(of: delimiter) else { split.append(nil); continue }
            split.append((String(line[line.startIndex..<r.lowerBound]),
                          String(line[r.upperBound...])))
        }
        let width = split.compactMap { $0 }
            .map { $0.head.trimmedTrailing().count }
            .max() ?? 0

        return zip(lines, split).map { line, piece in
            guard let piece else { return line }
            let head = piece.head.trimmedTrailing()
            let padding = String(repeating: " ", count: max(0, width - head.count))
            let tail = piece.tail.trimmedLeading()
            return head + padding + " " + delimiter + " " + tail
        }
    }

    // MARK: - case conversion

    static func camelCased(_ text: String) -> String {
        var out = ""
        var upcomingUpper = false
        for c in text {
            if c == "_" { upcomingUpper = true; continue }
            out.append(upcomingUpper ? Character(c.uppercased()) : c)
            upcomingUpper = false
        }
        return out
    }

    static func snakeCased(_ text: String) -> String {
        var out = ""
        for (i, c) in text.enumerated() {
            if c.isUppercase && i > 0 { out.append("_") }
            out.append(Character(c.lowercased()))
        }
        return out
    }
}

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespaces) }
    func trimmedTrailing() -> String {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }
    func trimmedLeading() -> String {
        var s = self
        while let first = s.first, first == " " || first == "\t" { s.removeFirst() }
        return s
    }
}
