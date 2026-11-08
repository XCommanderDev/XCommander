import Foundation

/// A node in the keymap trie: either a command or a group of further keys, never both.
///
/// That rule is what keeps the engine timeout-free. If `b` could be both a command and a
/// prefix, pressing it would mean waiting to see whether another key follows, and the wait
/// is the thing that makes an editor feel slow.
///
/// Leaves hold a **command id**, not a command. Register in the `CommandRegistry` first,
/// then bind by id — binding whole commands is how you end up with two copies that drift.
public indirect enum KeymapEntry: Hashable, Sendable {
    case command(String)
    case group(title: String, children: [KeyEvent: KeymapEntry])

    public var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

public enum KeymapError: Error, Equatable, CustomStringConvertible {
    case commandInThePath(prefix: String, existing: String)
    case groupWhereCommandExpected(prefix: String, group: String)
    case duplicate(prefix: String, existing: String)
    case emptySequence

    public var description: String {
        switch self {
        case .commandInThePath(let p, let e): "\(p) cannot be a prefix: it is already '\(e)'"
        case .groupWhereCommandExpected(let p, let g): "\(p) is already the group '\(g)'"
        case .duplicate(let p, let e): "\(p) is already bound to '\(e)'"
        case .emptySequence: "a binding needs at least one key"
        }
    }
}

public struct Keymap: Hashable, Sendable {
    public private(set) var children: [KeyEvent: KeymapEntry] = [:]
    private var groupTitles: [[KeyEvent]: String] = [:]

    public init() {}

    public mutating func bind(_ sequence: [KeyEvent], to commandID: String,
                              groupTitles titles: [[KeyEvent]: String] = [:]) throws {
        guard !sequence.isEmpty else { throw KeymapError.emptySequence }
        for (path, title) in titles { groupTitles[path] = title }
        children = try Self.insert(sequence, commandID, into: children,
                                   path: [], titles: groupTitles)
    }

    private static func insert(_ sequence: [KeyEvent], _ commandID: String,
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
                throw KeymapError.duplicate(prefix: label, existing: existing)
            case nil:
                children[head] = .command(commandID)
            }
            return children
        }

        let rest = Array(sequence.dropFirst())
        switch children[head] {
        case .some(.command(let existing)):
            throw KeymapError.commandInThePath(prefix: label, existing: existing)
        case .some(.group(let title, let grandchildren)):
            children[head] = .group(title: title,
                                    children: try insert(rest, commandID, into: grandchildren,
                                                         path: here, titles: titles))
        case nil:
            children[head] = .group(title: titles[here] ?? head.display,
                                    children: try insert(rest, commandID, into: [:],
                                                         path: here, titles: titles))
        }
        return children
    }

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

    /// The rows a which-key panel shows for a prefix. Titles come from the registry, which
    /// is what keeps the panel and the palette describing commands the same way.
    ///
    /// **A command the running Xcode does not have is not shown at all.** A key that is
    /// printed on the panel and then does nothing is the worst thing a keyboard tool can do:
    /// the user cannot tell a removed feature from a broken app, and they were told to press
    /// it. Hiding it means a user on an Xcode that lost a command never learns there was one,
    /// which is exactly right — it was never theirs to have.
    ///
    /// `isAvailable` defaults to "everything", because Core cannot see Xcode and a keymap
    /// tested headlessly should show its whole self.
    public func rows(at sequence: [KeyEvent], in registry: CommandRegistry,
                     shortcut: (Command) -> String? = { _ in nil },
                     isAvailable: (Command) -> Bool = { _ in true }) -> [WhichKeyRow] {
        let level: [KeyEvent: KeymapEntry]
        if sequence.isEmpty {
            level = children
        } else if case .some(.group(_, let kids)) = entry(at: sequence) {
            level = kids
        } else {
            return []
        }
        return level.compactMap { key, entry -> WhichKeyRow? in
            switch entry {
            case .command(let id):
                guard let command = registry.command(id: id) else {
                    // A binding to an unregistered id is a programming error, but a missing
                    // row is better than a crash in front of the user.
                    return WhichKeyRow(key: key.display, title: "?\(id)", isGroup: false)
                }
                guard isAvailable(command) else { return nil }
                return WhichKeyRow(key: key.display, title: command.title, isGroup: false,
                                   shortcut: shortcut(command), menuRef: command.menuRef)
            case .group(let title, _):
                return WhichKeyRow(key: key.display, title: title, isGroup: true)
            }
        }.sorted()
    }

    /// Where a command lives in the tree, for the palette's binding column. The palette
    /// showing `⌥RET m m` next to "Product > Build" is what makes it teach the keymap
    /// rather than compete with it.
    public func binding(for commandID: String) -> [KeyEvent]? {
        func search(_ level: [KeyEvent: KeymapEntry], _ prefix: [KeyEvent]) -> [KeyEvent]? {
            for (key, entry) in level {
                switch entry {
                case .command(let id) where id == commandID: return prefix + [key]
                case .group(_, let kids):
                    if let hit = search(kids, prefix + [key]) { return hit }
                default: continue
                }
            }
            return nil
        }
        return search(children, [])
    }
}
