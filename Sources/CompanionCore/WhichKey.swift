import Foundation

/// One line of the which-key panel.
public struct WhichKeyRow: Hashable, Sendable, Comparable, Identifiable {
    public var key: String
    public var title: String
    public var isGroup: Bool
    /// The Xcode shortcut behind a leaf, shown dimmed so the panel teaches the native
    /// binding as well as ours. Nil for groups.
    ///
    /// Filled in by the app, not by Core: what a menu path is bound to is a fact about the
    /// running Xcode and the user's keyboard layout, and Core knows about neither.
    public var shortcut: String?
    /// The menu path behind a leaf, so the app can look its shortcut up.
    public var menuPath: [String]?

    public var id: String { key }

    public init(key: String, title: String, isGroup: Bool,
                shortcut: String? = nil, menuPath: [String]? = nil) {
        self.key = key
        self.title = title
        self.isGroup = isGroup
        self.shortcut = shortcut
        self.menuPath = menuPath
    }

    /// What the panel prints: `+build` for a group, `build` for a command.
    public var label: String { isGroup ? "+" + title : title }

    /// Lower case before upper case for the same letter, so `f` and `F` sit together
    /// and in a predictable order. Plain `<` would put every capital first.
    public static func < (a: WhichKeyRow, b: WhichKeyRow) -> Bool {
        let la = a.key.lowercased(), lb = b.key.lowercased()
        if la != lb { return la < lb }
        return a.key > b.key
    }
}

/// Everything the overlay needs to draw itself.
public struct WhichKeyPanel: Hashable, Sendable {
    /// The keys pressed so far, e.g. `⌥SPC b`.
    public var breadcrumb: String
    public var rows: [WhichKeyRow]

    public init(breadcrumb: String, rows: [WhichKeyRow]) {
        self.breadcrumb = breadcrumb
        self.rows = rows
    }
}
