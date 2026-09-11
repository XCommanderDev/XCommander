import Foundation

/// The nine navigators in Xcode's left-hand pane.
///
/// The raw value is **Xcode's own name for the navigator**, which is both its menu title
/// under `View > Navigators >` and the `AXDescription` on its selector button. Keeping one
/// string for both means there is one table rather than a mapping to get wrong; `title` is
/// the separate, lower-case Doom-style name the which-key panel shows.
///
/// Selecting one goes through the menu like everything else, and the menu item **reveals the
/// pane if it is hidden**, so there is no special case for that. Only *focusing* the
/// navigator needs Accessibility — see `NavigatorController`.
public enum XcodeNavigator: String, Hashable, Sendable, CaseIterable {
    case project = "Project"
    case sourceControl = "Source Control"
    case bookmarks = "Bookmarks"
    case find = "Find"
    case issues = "Issues"
    case tests = "Tests"
    case debug = "Debug"
    case breakpoints = "Breakpoints"
    case reports = "Reports"

    /// Where this navigator lives in Xcode's menu bar.
    public var menuPath: [String] { ["View", "Navigators", rawValue] }

    public var title: String {
        switch self {
        case .project: "project"
        case .sourceControl: "source control"
        case .bookmarks: "bookmarks"
        case .find: "find results"
        case .issues: "issues"
        case .tests: "tests"
        case .debug: "debug"
        case .breakpoints: "breakpoints"
        case .reports: "reports"
        }
    }

    /// A stable command id, independent of the display name.
    public var commandID: String {
        switch self {
        case .project: "navigator.project"
        case .sourceControl: "navigator.sourceControl"
        case .bookmarks: "navigator.bookmarks"
        case .find: "navigator.find"
        case .issues: "navigator.issues"
        case .tests: "navigator.tests"
        case .debug: "navigator.debug"
        case .breakpoints: "navigator.breakpoints"
        case .reports: "navigator.reports"
        }
    }

    /// The command that shows this navigator. A plain menu command, like everything else
    /// that Xcode's menu bar can already do.
    public var command: Command {
        .menu(commandID, title, menuPath)
    }
}


/// A part of Xcode's window the keyboard can be sent into.
///
/// These are the places where "focus it" is a real verb — a list you then walk with the arrow
/// keys — and where the menu bar has no item that does it. The inspector is deliberately
/// absent: its content is a form of text fields and popup buttons, so there is nothing
/// coherent to focus, and pretending otherwise would put a command in the panel that does
/// nothing useful. The console is absent for the opposite reason: `Debug Area > Activate
/// Console` already focuses it, so it is an ordinary menu command.
public enum XcodeArea: String, Hashable, Sendable, CaseIterable {
    /// The left-hand pane's tree.
    case navigator
    /// The debug area's variables list.
    case variables

    public var title: String {
        switch self {
        case .navigator: "focus navigator"
        case .variables: "focus variables"
        }
    }

    public var commandID: String {
        switch self {
        case .navigator: "navigator.focus"
        case .variables: "debug.focusVariables"
        }
    }

    public var searchText: String {
        switch self {
        case .navigator: "put the keyboard in the navigator"
        case .variables: "put the keyboard in the debug variables list"
        }
    }

    public var command: Command {
        Command(id: commandID, title: title, searchText: searchText, action: .focus(self))
    }
}
