import Foundation

/// How a command reaches Xcode.
///
/// The tiers from the spike report, in the order the executor tries them. Tier 1b
/// (assigning our own shortcut through `NSUserKeyEquivalents`) is deliberately absent:
/// it is faster on paper and it mutates another application's preferences, which is
/// not something to do by default. See `SPIKE-REPORT.md`.
public enum CommandAction: Hashable, Sendable {
    /// Tier 1 — synthesise a shortcut Xcode already has. ~40 µs.
    case shortcut(KeyEvent)
    /// Tier 2 — press the menu item over Accessibility. ~1 ms once the element is cached.
    case menuPath([String])
    /// Ours, not Xcode's: quit, reload config, show the palette.
    case companion(String)
}

/// A single thing the leader key can do.
public struct Command: Hashable, Sendable, Identifiable {
    public var id: String
    /// What the which-key panel shows. Lower case, terse, Doom-style.
    public var title: String
    public var action: CommandAction

    public init(id: String, title: String, action: CommandAction) {
        self.id = id
        self.title = title
        self.action = action
    }

    /// Convenience for the common case: a command that fires an existing Xcode shortcut.
    public static func shortcut(_ id: String, _ title: String,
                                _ key: Key, _ modifiers: Modifiers) -> Command {
        Command(id: id, title: title, action: .shortcut(KeyEvent(key, modifiers)))
    }

    /// The shortcut as it would read in a menu, or nil for anything that is not tier 1.
    public var shortcutDisplay: String? {
        guard case .shortcut(let e) = action else { return nil }
        return e.display
    }

    /// The menu path, for commands that name one.
    public var menuPath: [String]? {
        guard case .menuPath(let path) = action else { return nil }
        return path
    }
}
