import Foundation

/// How a command reaches Xcode.
public enum CommandAction: Hashable, Sendable {
    /// Tier 1 — synthesise a shortcut Xcode already has. ~40 µs.
    case shortcut(KeyEvent)
    /// Tier 1 when the item has a shortcut, tier 2 (`AXPress`, ~1 ms) when it does not.
    case menuPath([String])
    /// Transform the editor's selection in place, through the writable `AXTextArea`.
    /// Xcode's own undo reverts it.
    case transform(TextTransform)
    /// Open a picker. The payload names which one; the app supplies its rows.
    case picker(PickerKind)
    /// Ours: quit, reload.
    case companion(String)
}

/// The pickers the product knows how to open.
public enum PickerKind: String, Hashable, Sendable, CaseIterable {
    case commands          // every Xcode command, fuzzy
    case files             // files in the project
    case buffers           // open editor tabs
    case destinations      // Product > Destination, 80 items deep
    case schemes
    case themes
    case syntaxColoring
    case recentProjects
    case menuSlice         // "fuzzy whatever submenu I name"

    public var title: String {
        switch self {
        case .commands: "Commands"
        case .files: "Files"
        case .buffers: "Open Editors"
        case .destinations: "Destination"
        case .schemes: "Scheme"
        case .themes: "Theme"
        case .syntaxColoring: "Syntax Coloring"
        case .recentProjects: "Recent Projects"
        case .menuSlice: "Menu"
        }
    }
}

/// A single thing the leader key, or the palette, can do.
public struct Command: Hashable, Sendable, Identifiable {
    public var id: String
    /// Terse, lower case, Doom-style. What the which-key panel shows.
    public var title: String
    /// What the palette's matcher searches. For a menu command this is the full path, so
    /// `Product > Build` is findable by "prbu" as well as by "build".
    public var searchText: String
    public var action: CommandAction

    public init(id: String, title: String, searchText: String? = nil, action: CommandAction) {
        self.id = id
        self.title = title
        self.searchText = searchText ?? title
        self.action = action
    }

    public var menuPath: [String]? {
        guard case .menuPath(let path) = action else { return nil }
        return path
    }

    /// The shortcut as it would read in a menu, for commands that name one directly.
    public var shortcutDisplay: String? {
        guard case .shortcut(let e) = action else { return nil }
        return e.display
    }

    /// A command backed by an Xcode menu item.
    public static func menu(_ id: String, _ title: String, _ path: [String]) -> Command {
        Command(id: id, title: title,
                searchText: path.joined(separator: " > "),
                action: .menuPath(path))
    }

    /// A command that opens a picker.
    public static func picker(_ id: String, _ title: String, _ kind: PickerKind,
                              searchText: String? = nil) -> Command {
        Command(id: id, title: title, searchText: searchText ?? title, action: .picker(kind))
    }

    /// A command that rewrites the selection.
    public static func transform(_ id: String, _ title: String, _ transform: TextTransform,
                                 searchText: String? = nil) -> Command {
        Command(id: id, title: title, searchText: searchText ?? title, action: .transform(transform))
    }
}
