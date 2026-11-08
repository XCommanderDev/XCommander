import Foundation

/// The value kinds a configuration file can hold.
public indirect enum TOMLValue: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .boolean(let b) = self { b } else { nil } }
    public var arrayValue: [TOMLValue]? { if case .array(let a) = self { a } else { nil } }
    public var tableValue: [String: TOMLValue]? { if case .table(let t) = self { t } else { nil } }

    /// Integers and floats are the same thing to a user typing `350` or `0.35`, and every
    /// number this format carries is a duration or a count.
    public var numberValue: Double? {
        switch self {
        case .integer(let i): Double(i)
        case .double(let d): d
        default: nil
        }
    }
}

/// One `key = value`, flattened to a full path and stamped with where it was written.
///
/// The parser deliberately does **not** build a nested tree. A tree would have to be walked
/// again by the decoder, and — the part that matters — a tree has nowhere natural to keep a
/// line number for every leaf. A flat list of `(path, value, line)` is exactly what a decoder
/// wants, and it is what makes `config.toml:14` reachable from any error.
public struct TOMLEntry: Hashable, Sendable {
    public var path: [String]
    public var value: TOMLValue
    public var line: Int
}

public struct TOMLDocument: Sendable {
    public var entries: [TOMLEntry] = []
    /// Every `[table.header]` seen, so a whole section can be reported at its own line —
    /// `[layouts.debugging] is not implemented` points at the header, not at a key.
    public var tables: [(path: [String], line: Int)] = []

    public func value(at path: [String]) -> TOMLValue? {
        entries.first { $0.path == path }?.value
    }

    public func entry(at path: [String]) -> TOMLEntry? {
        entries.first { $0.path == path }
    }

    /// Every entry directly inside a table: `children(of: ["keys"])` is the bindings.
    public func children(of path: [String]) -> [TOMLEntry] {
        entries.filter { $0.path.count == path.count + 1 && Array($0.path.dropLast()) == path }
    }

    /// The declared table headers one level below a path, with their lines.
    public func subtables(of path: [String]) -> [(name: String, line: Int)] {
        tables.compactMap { table in
            guard table.path.count == path.count + 1,
                  Array(table.path.dropLast()) == path else { return nil }
            return (table.path[table.path.count - 1], table.line)
        }
    }
}

/// A small TOML reader: enough of the format for a configuration file, and no more.
///
/// **Why hand-written rather than a dependency.** Two reasons, and the second is the real
/// one. `XCommanderCore` has no dependencies at all, which is what lets it build and test in
/// under a second on any machine — but more importantly, the diagnostics *are* the feature
/// here (see `ConfigDiagnostic`), and a general-purpose parser reports what is wrong with a
/// document rather than what is wrong with a user's keymap. Owning the reader means an error
/// can say "a binding's value must be a command id" at the line where the value sits.
///
/// What it accepts: comments, table headers, bare and quoted keys, dotted keys, strings,
/// integers, floats, booleans, arrays and inline tables, nested and spanning lines. What it
/// rejects, with a diagnostic rather than a crash: arrays of tables (`[[x]]`), multi-line
/// strings, dates. If a config file ever needs those, that is the moment to reach for a real
/// TOML library — and because everything downstream consumes `[TOMLEntry]`, swapping the
/// reader is a change to this file alone.
public enum TOML {

    public static func parse(_ text: String, source: String)
        -> (document: TOMLDocument, diagnostics: [ConfigDiagnostic]) {
        var scanner = Scanner(text: text, source: source)
        scanner.run()
        return (scanner.document, scanner.diagnostics)
    }

    private struct Scanner {
        let characters: [Character]
        let source: String
        var index = 0
        var line = 1
        var prefix: [String] = []
        var document = TOMLDocument()
        var diagnostics: [ConfigDiagnostic] = []

        init(text: String, source: String) {
            self.characters = Array(text)
            self.source = source
        }

        var atEnd: Bool { index >= characters.count }
        func peek(_ offset: Int = 0) -> Character? {
            let i = index + offset
            return i < characters.count ? characters[i] : nil
        }

        mutating func advance() {
            if peek() == "\n" { line += 1 }
            index += 1
        }

        mutating func error(_ message: String, at line: Int? = nil) {
            diagnostics.append(ConfigDiagnostic(.error, source: source,
                                                line: line ?? self.line, message))
        }

        /// Past whitespace, comments and newlines, to the next thing that means something.
        mutating func skipTrivia() {
            while let c = peek() {
                if c == "#" {
                    while let c = peek(), c != "\n" { advance() }
                } else if c.isWhitespace {
                    advance()
                } else {
                    return
                }
            }
        }

        mutating func skipInlineSpace() {
            while let c = peek(), c == " " || c == "\t" { advance() }
        }

        mutating func run() {
            while true {
                skipTrivia()
                guard !atEnd else { return }
                if peek() == "[" {
                    parseTableHeader()
                } else {
                    parseKeyValue()
                }
            }
        }

        mutating func parseTableHeader() {
            let start = line
            advance()                                   // [
            if peek() == "[" {
                error("arrays of tables ([[…]]) are not part of this format", at: start)
                while let c = peek(), c != "\n" { advance() }
                return
            }
            var path: [String] = []
            while true {
                skipInlineSpace()
                guard let name = parseKeyComponent() else {
                    error("a table header needs a name", at: start)
                    while let c = peek(), c != "\n" { advance() }
                    return
                }
                path.append(name)
                skipInlineSpace()
                if peek() == "." { advance(); continue }
                break
            }
            guard peek() == "]" else {
                error("a table header must end with ']'", at: start)
                while let c = peek(), c != "\n" { advance() }
                return
            }
            advance()
            prefix = path
            document.tables.append((path: path, line: start))
        }

        mutating func parseKeyValue() {
            let start = line
            var path: [String] = []
            while true {
                skipInlineSpace()
                guard let name = parseKeyComponent() else {
                    error("expected a key", at: start)
                    while let c = peek(), c != "\n" { advance() }
                    return
                }
                path.append(name)
                skipInlineSpace()
                if peek() == "." { advance(); continue }
                break
            }
            skipInlineSpace()
            guard peek() == "=" else {
                error("expected '=' after '\(path.joined(separator: "."))'", at: start)
                while let c = peek(), c != "\n" { advance() }
                return
            }
            advance()
            skipInlineSpace()
            guard let value = parseValue(startedAt: start) else {
                while let c = peek(), c != "\n" { advance() }
                return
            }
            document.entries.append(TOMLEntry(path: prefix + path, value: value, line: start))
        }

        /// A bare key, or a quoted one — `"m m"` has a space in it, so quoting is not
        /// optional in this format's most common line.
        mutating func parseKeyComponent() -> String? {
            if peek() == "\"" { return parseString() }
            var out = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "-" {
                out.append(c)
                advance()
            }
            return out.isEmpty ? nil : out
        }

        mutating func parseString() -> String? {
            let start = line
            advance()                                   // opening quote
            var out = ""
            while let c = peek() {
                if c == "\\" {
                    advance()
                    guard let escaped = peek() else { break }
                    switch escaped {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(escaped)
                    }
                    advance()
                } else if c == "\"" {
                    advance()
                    return out
                } else if c == "\n" {
                    break
                } else {
                    out.append(c)
                    advance()
                }
            }
            error("unterminated string", at: start)
            return nil
        }

        mutating func parseValue(startedAt start: Int) -> TOMLValue? {
            switch peek() {
            case "\"":
                return parseString().map(TOMLValue.string)
            case "[":
                return parseArray(startedAt: start)
            case "{":
                return parseInlineTable(startedAt: start)
            default:
                return parseBareValue(startedAt: start)
            }
        }

        mutating func parseArray(startedAt start: Int) -> TOMLValue? {
            advance()                                   // [
            var items: [TOMLValue] = []
            while true {
                skipTrivia()                            // arrays may span lines
                if peek() == "]" { advance(); return .array(items) }
                guard !atEnd else {
                    error("unterminated array", at: start)
                    return nil
                }
                guard let item = parseValue(startedAt: start) else { return nil }
                items.append(item)
                skipTrivia()
                if peek() == "," { advance(); continue }
                if peek() == "]" { advance(); return .array(items) }
                error("expected ',' or ']' in an array", at: start)
                return nil
            }
        }

        mutating func parseInlineTable(startedAt start: Int) -> TOMLValue? {
            advance()                                   // {
            var table: [String: TOMLValue] = [:]
            while true {
                skipTrivia()
                if peek() == "}" { advance(); return .table(table) }
                guard !atEnd else {
                    error("unterminated inline table", at: start)
                    return nil
                }
                guard let key = parseKeyComponent() else {
                    error("expected a key in an inline table", at: start)
                    return nil
                }
                skipInlineSpace()
                guard peek() == "=" else {
                    error("expected '=' after '\(key)'", at: start)
                    return nil
                }
                advance()
                skipInlineSpace()
                guard let value = parseValue(startedAt: start) else { return nil }
                table[key] = value
                skipTrivia()
                if peek() == "," { advance(); continue }
                if peek() == "}" { advance(); return .table(table) }
                error("expected ',' or '}' in an inline table", at: start)
                return nil
            }
        }

        mutating func parseBareValue(startedAt start: Int) -> TOMLValue? {
            var token = ""
            while let c = peek(), !c.isWhitespace, c != ",", c != "]", c != "}", c != "#" {
                token.append(c)
                advance()
            }
            if token == "true" { return .boolean(true) }
            if token == "false" { return .boolean(false) }
            if let i = Int(token) { return .integer(i) }
            if let d = Double(token) { return .double(d) }
            if token.isEmpty {
                error("expected a value", at: start)
            } else {
                error("'\(token)' is not a value this format understands "
                      + "(a string needs quotes)", at: start)
            }
            return nil
        }
    }
}
