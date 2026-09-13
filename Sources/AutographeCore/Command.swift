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
    /// Move focus to the pane in a direction, or resize around the current divider.
    /// Xcode can only cycle between panes; direction, balance and zoom are ours.
    case pane(PaneAction)
    /// Put the keyboard into a part of the window the menu bar cannot target. `View >
    /// Navigators >` selects a navigator but does not focus it, and `Navigate > Move Focus to
    /// Next Area` only *cycles* — three presses to reach the navigator from the editor.
    case focus(XcodeArea)
    /// Ours: quit, reload.
    case companion(String)
}

/// What the pane commands do.
///
/// `focus`, `balance`, `zoom`, `grow` and `shrink` drive Xcode's own split view. `swap` and
/// `send` have **no Xcode equivalent at all** and are synthesised: Xcode can cycle focus
/// between panes and open into the "next" one, but it cannot exchange two panes or target a
/// direction. Both are built from reading each pane's document and re-opening it elsewhere.
public enum PaneAction: Hashable, Sendable {
    case focus(PaneDirection)
    case balance, zoom, grow, shrink
    /// Exchange the focused pane's file with the next pane's. Vim's `⌃w x`.
    case swap
    /// Open the focused pane's file in the pane in this direction, and go there.
    ///
    /// Deliberately *not* vim's `⌃w H/J/K/L`, which moves the window itself. The split
    /// tree's shape is not writable from outside Xcode, so moving a pane is impossible;
    /// sending the buffer is the half that is both possible and useful.
    case send(PaneDirection)
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
    case projectSearch     // ripgrep over the project, results in the picker
    case documentSymbols   // declarations in the current file, from Xcode's index
    case projectSymbols    // declarations across the project, from Xcode's index

    /// Which shape of preview this picker's rows want, if any.
    ///
    /// Exhaustive with no `default` on purpose: the day a twelfth picker is added the compiler
    /// asks which of the three it is, which is the only thing that keeps a policy like this
    /// from rotting. The rule is the question the list leaves open — a row that *is* the answer
    /// (a command, a destination) needs no pane.
    public var previewStyle: PreviewStyle {
        switch self {
        // **Only the project search.** A preview earns a pane when the row is a *location* —
        // one line torn out of a file, where the surrounding lines are the decision. Every
        // other picker's row is already the answer: a file name tells you the file, a command
        // tells you the command, and a pane beside them is furniture.
        case .projectSearch: .text
        case .files, .buffers, .documentSymbols, .projectSymbols,
             .commands, .destinations, .schemes, .themes, .syntaxColoring, .recentProjects: .none
        }
    }

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
        case .projectSearch: "Search Project"
        case .documentSymbols: "Symbols in File"
        case .projectSymbols: "Project Symbols"
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

    /// A command that moves or resizes an editor pane.
    public static func pane(_ id: String, _ title: String, _ action: PaneAction,
                            searchText: String? = nil) -> Command {
        Command(id: id, title: title, searchText: searchText ?? title, action: .pane(action))
    }

    /// A command that rewrites the selection.
    public static func transform(_ id: String, _ title: String, _ transform: TextTransform,
                                 searchText: String? = nil) -> Command {
        Command(id: id, title: title, searchText: searchText ?? title, action: .transform(transform))
    }
}
