import Foundation

/// One row in a picker.
public struct PickerItem: Hashable, Sendable, Identifiable {
    public let id: String
    /// The line the user reads.
    public let title: String
    /// What the matcher searches, which is not always what is shown. "balance panes" is
    /// the useful label, but the command should also be findable by "make the panes equal"
    /// — and a command found only by its description loses to any Xcode menu item that
    /// happens to contain the word you typed.
    public let matchText: String
    /// Shown dimmed on the right: a key binding, a file's directory, a scheme's platform.
    public let detail: String?
    /// Greyed and unselectable. Xcode's menus are context-dependent, so a command offered
    /// a moment ago can be unavailable now.
    public let isEnabled: Bool

    public init(id: String, title: String, detail: String? = nil,
                isEnabled: Bool = true, matchText: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isEnabled = isEnabled
        self.matchText = matchText ?? title
    }
}

/// Where a picker's rows come from.
public enum PickerSource: Hashable, Sendable {
    /// A fixed list, filtered and ranked by the fuzzy matcher as you type.
    case staticList
    /// Rows supplied from outside on every keystroke — a project-wide search, where the
    /// query goes to `rg` rather than to the matcher. The session does no filtering of its
    /// own, because the results are already the answer to the query.
    case dynamic
}

/// A matched row, with the positions to highlight.
public struct PickerRow: Hashable, Sendable {
    public let item: PickerItem
    public let matched: [Int]
}

public enum PickerOutcome: Hashable, Sendable {
    case updated
    case chosen(PickerItem)
    case cancelled
    /// A key the picker has no use for. Swallowed anyway: while a picker is open every
    /// keystroke is ours, or half of them would land in the editor behind it.
    case ignored
}

/// The picker, as logic.
///
/// All of it is here rather than in the window: filtering, selection, and every editing
/// key. The overlay draws `rows` and `selection` and nothing else, which is what makes the
/// behaviour testable without a screen.
public struct PickerSession: Sendable {
    public let title: String
    public let source: PickerSource
    public private(set) var query = ""
    public private(set) var rows: [PickerRow] = []
    public private(set) var selection = 0
    private let items: [PickerItem]

    /// How many rows the overlay can show at once. Only used for page up/down.
    public var pageSize = 8

    public init(title: String, items: [PickerItem], source: PickerSource = .staticList) {
        self.title = title
        self.items = items
        self.source = source
        refilter()
    }

    /// Supply rows for a `.dynamic` picker. The selection is clamped rather than preserved,
    /// for the same reason it is when a static list shrinks: the row under the cursor is a
    /// different row now.
    public mutating func replaceRows(_ items: [PickerItem]) {
        rows = items.map { PickerRow(item: $0, matched: []) }
        selection = rows.isEmpty ? 0 : min(selection, rows.count - 1)
    }

    public var selectedItem: PickerItem? {
        rows.indices.contains(selection) ? rows[selection].item : nil
    }

    public mutating func press(_ event: KeyEvent) -> PickerOutcome {
        // Esc always leaves, from any state. The same rule as the which-key panel.
        if event == .escape { return .cancelled }

        switch event.key {
        case .special(let special):
            return handle(special, event.modifiers)
        case .character(let character):
            // Control- and Command-chords are navigation, not text.
            if event.modifiers.contains(.control) || event.modifiers.contains(.command) {
                return handleChord(character, event.modifiers)
            }
            query.append(character)
            refilter()
            return .updated
        }
    }

    private mutating func handle(_ special: SpecialKey, _ modifiers: Modifiers) -> PickerOutcome {
        switch special {
        case .return:
            guard let item = selectedItem, item.isEnabled else { return .ignored }
            return .chosen(item)
        case .delete:
            if modifiers.contains(.option) { deleteWord() } else if !query.isEmpty { query.removeLast() }
            refilter()
            return .updated
        case .down:     move(by: 1);  return .updated
        case .up:       move(by: -1); return .updated
        case .pageDown: move(by: pageSize);  return .updated
        case .pageUp:   move(by: -pageSize); return .updated
        case .home:     selection = 0; return .updated
        case .end:      selection = max(0, rows.count - 1); return .updated
        case .tab:      move(by: modifiers.contains(.shift) ? -1 : 1); return .updated
        case .space:
            query.append(" ")
            refilter()
            return .updated
        case .escape:   return .cancelled
        case .left, .right:
            return .ignored
        }
    }

    /// The Emacs chords, because the people this is for already have them in their hands.
    private mutating func handleChord(_ character: Character, _ modifiers: Modifiers) -> PickerOutcome {
        guard modifiers.contains(.control) else { return .ignored }
        switch character {
        case "n", "j": move(by: 1);  return .updated
        case "p", "k": move(by: -1); return .updated
        case "u": query = ""; refilter(); return .updated
        case "w": deleteWord(); refilter(); return .updated
        case "a": selection = 0; return .updated
        case "e": selection = max(0, rows.count - 1); return .updated
        case "g": return .cancelled
        default:  return .ignored
        }
    }

    private mutating func deleteWord() {
        while let last = query.last, last == " " { query.removeLast() }
        while let last = query.last, last != " " { query.removeLast() }
    }

    /// Selection wraps. In a list you drive blind from the home row, wrapping is what you
    /// want: holding the key never dead-ends.
    private mutating func move(by delta: Int) {
        guard !rows.isEmpty else { selection = 0; return }
        selection = ((selection + delta) % rows.count + rows.count) % rows.count
    }

    private mutating func refilter() {
        // A dynamic picker's rows answer the query already; filtering them again by the
        // same text would drop hits whose match is on the line rather than in the path.
        guard source == .staticList else { return }
        let ranked = FuzzyMatcher.rank(items, query: query) { $0.matchText }
        rows = ranked.map { PickerRow(item: $0.item, matched: $0.match.matched) }
        // Re-clamp rather than preserve: after typing, the row under the cursor is a
        // different row, and keeping an index into a list that changed under it is how
        // pickers end up running the wrong command.
        selection = rows.isEmpty ? 0 : min(selection, rows.count - 1)
    }
}
