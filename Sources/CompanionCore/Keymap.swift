import Foundation

/// A node in the keymap trie: either a command or a group of further keys, never both.
///
/// That rule is what keeps the engine timeout-free. If `b` could be *both* a command and
/// a prefix, pressing it would mean waiting to see whether another key follows, and the
/// wait is the thing that makes an editor feel slow. Forbidding the ambiguity means every
/// press is decided the instant it arrives.
public indirect enum KeymapEntry: Hashable, Sendable {
    case command(Command)
    case group(title: String, children: [KeyEvent: KeymapEntry])

    public var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

public enum KeymapError: Error, Equatable, CustomStringConvertible {
    /// A sequence would have to pass *through* a leaf command to reach its target.
    case commandInThePath(prefix: String, existing: String)
    /// A sequence ends on a key that is already a group.
    case groupWhereCommandExpected(prefix: String, group: String)
    /// Two commands claim the same sequence.
    case duplicate(prefix: String, existing: String)
    case emptySequence

    public var description: String {
        switch self {
        case .commandInThePath(let p, let e):
            "\(p) cannot be a prefix: it is already the command '\(e)'"
        case .groupWhereCommandExpected(let p, let g):
            "\(p) is already the group '\(g)', so it cannot also be a command"
        case .duplicate(let p, let e):
            "\(p) is already bound to '\(e)'"
        case .emptySequence:
            "a binding needs at least one key"
        }
    }
}

/// The trie itself, plus the walk.
public struct Keymap: Hashable, Sendable {
    public private(set) var children: [KeyEvent: KeymapEntry] = [:]
    /// Titles for prefixes, e.g. ["b"] -> "build". Set as a side effect of binding.
    private var groupTitles: [[KeyEvent]: String] = [:]

    public init() {}

    /// Bind a sequence to a command, creating any intermediate groups.
    ///
    /// `groupTitles` names the prefixes so the which-key panel can say `+build` rather
    /// than the key on its own. A prefix with no registered title falls back to its key.
    public mutating func bind(_ sequence: [KeyEvent], to command: Command,
                              groupTitles titles: [[KeyEvent]: String] = [:]) throws {
        guard !sequence.isEmpty else { throw KeymapError.emptySequence }
        for (path, title) in titles { groupTitles[path] = title }
        children = try Self.insert(sequence, command, into: children,
                                   path: [], titles: groupTitles)
    }

    private static func insert(_ sequence: [KeyEvent], _ command: Command,
                               into children: [KeyEvent: KeymapEntry],
                               path: [KeyEvent],
                               titles: [[KeyEvent]: String]) throws -> [KeyEvent: KeymapEntry] {
        var children = children
        let head = sequence[0]
        let here = path + [head]
        let label = here.map(\.display).joined(separator: " ")

        if sequence.count == 1 {
            switch children[head] {
            case .some(.group(let title, _)):
                throw KeymapError.groupWhereCommandExpected(prefix: label, group: title)
            case .some(.command(let existing)):
                throw KeymapError.duplicate(prefix: label, existing: existing.title)
            case nil:
                children[head] = .command(command)
            }
            return children
        }

        let rest = Array(sequence.dropFirst())
        switch children[head] {
        case .some(.command(let existing)):
            throw KeymapError.commandInThePath(prefix: label, existing: existing.title)
        case .some(.group(let title, let grandchildren)):
            children[head] = .group(title: title,
                                    children: try insert(rest, command, into: grandchildren,
                                                         path: here, titles: titles))
        case nil:
            children[head] = .group(title: titles[here] ?? head.display,
                                    children: try insert(rest, command, into: [:],
                                                         path: here, titles: titles))
        }
        return children
    }

    /// Follow a sequence from the root. Returns nil if it leaves the trie.
    public func entry(at sequence: [KeyEvent]) -> KeymapEntry? {
        var current: KeymapEntry? = nil
        var level = children
        for key in sequence {
            guard let next = level[key] else { return nil }
            current = next
            if case .group(_, let kids) = next { level = kids } else { level = [:] }
        }
        return current
    }

    /// The rows a which-key panel should show for a prefix (empty prefix = the root).
    public func rows(at sequence: [KeyEvent]) -> [WhichKeyRow] {
        let level: [KeyEvent: KeymapEntry]
        if sequence.isEmpty {
            level = children
        } else if case .some(.group(_, let kids)) = entry(at: sequence) {
            level = kids
        } else {
            return []
        }
        return level.map { key, entry in
            switch entry {
            case .command(let c):
                WhichKeyRow(key: key.display, title: c.title, isGroup: false,
                            shortcut: c.shortcutDisplay, menuPath: c.menuPath)
            case .group(let title, _):
                WhichKeyRow(key: key.display, title: title, isGroup: true, shortcut: nil)
            }
        }.sorted()
    }
}
