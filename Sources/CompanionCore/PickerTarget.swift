import Foundation

/// What a chosen picker row actually refers to.
///
/// Rows carry a string id because a picker is a list of strings, but four different pickers
/// put four different things in it. Parsing that id was inline in the app delegate, spread
/// across an if/else chain, which is how one of the four came to open files by a different
/// mechanism than the other three — and only that one was broken.
public enum PickerTarget: Equatable, Sendable {
    /// A registered command, run through the executor.
    case command(String)
    /// A path through Xcode's menu bar.
    case menu([String])
    /// A file to open in Xcode, optionally at a line.
    case file(path: String, line: Int?)

    /// The separator inside a `menu:` id. A control character, because menu titles contain
    /// every printable one — including the `>` that would be the obvious choice.
    public static let menuSeparator = "\u{1}"

    /// The encoder for `menu:` ids. Paired with `parse` here so the separator cannot be
    /// written one way at the call site and read another way in the parser.
    public static func menuID(_ path: [String]) -> String {
        "menu:" + path.joined(separator: menuSeparator)
    }

    /// Arguments for `xed`, the developer tools' "open in Xcode" command. Here rather than
    /// beside the `Process` that runs it, so the line flag is checked by a test instead of
    /// by launching Xcode.
    public static func xedArguments(path: String, line: Int?) -> [String] {
        guard let line, line > 0 else { return [path] }
        return ["--line", String(line), path]
    }

    public static func parse(_ id: String) -> PickerTarget {
        if let body = id.dropPrefix("menu:") {
            return .menu(body.components(separatedBy: menuSeparator))
        }
        if let body = id.dropPrefix("symbol:") ?? id.dropPrefix("match:") {
            // "<path>:<line>". The path may itself contain colons, so the line is taken from
            // the end rather than by splitting from the front.
            guard let separator = body.lastIndex(of: ":"),
                  let line = Int(body[body.index(after: separator)...]) else {
                return .file(path: body, line: nil)
            }
            return .file(path: String(body[body.startIndex..<separator]), line: line)
        }
        if let body = id.dropPrefix("file:") {
            return .file(path: body, line: nil)
        }
        return .command(id)
    }
}

private extension String {
    /// `nil` when the prefix is absent, so two attempts can be chained with `??`.
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

/// How a file is labelled in the picker: its path relative to the project root.
public enum ProjectPath {
    /// `nil` when the file is not under the root, so the caller can fall back rather than
    /// slice a string that does not start where it thinks it does.
    ///
    /// The naive version — `String(path.dropFirst(root.count + 1))` — cuts by *length*, so
    /// when the two disagree about symlinks it silently produces a mangled label: a root of
    /// `/tmp/proj` against a file of `/private/tmp/proj/a.json` drops 10 characters and
    /// yields `mp/proj/a.json`. Compare before cutting.
    public static func relative(of path: String, under root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
