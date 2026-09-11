import Foundation

/// The leaders a user is allowed to choose.
///
/// **A closed list, not a key recorder, and that is the design.** A leader is swallowed while
/// Xcode is frontmost, so a leader that can be typed as text arms a sequence by accident and
/// the next word runs a command — the defect that moved the default off `⇧Space` (Chapter 5).
/// A recorder would let a user reintroduce it in one keystroke, and they would have no way to
/// know they had.
///
/// Offering a vetted list makes the failure unreachable rather than validated-against, which
/// is the same argument as the default itself. It also sidesteps a second problem: recording a
/// chord inside our own settings window, while our own event tap is running, is fiddly for no
/// benefit.
///
/// Every option here is a chord over a key that produces no character.
public enum LeaderChoice: String, Hashable, Sendable, CaseIterable {
    case optionReturn
    case commandEscape
    case controlReturn
    case controlSpace
    case optionSpace

    public static let `default` = LeaderChoice.optionReturn

    public var event: KeyEvent {
        switch self {
        case .optionReturn:  KeyEvent(.return, [.option])
        case .commandEscape: KeyEvent(.escape, [.command])
        case .controlReturn: KeyEvent(.return, [.control])
        case .controlSpace:  KeyEvent(.space, [.control])
        case .optionSpace:   KeyEvent(.space, [.option])
        }
    }

    /// How it reads in the popup. Spaced out rather than `display`'s terse `⌥RET`, because
    /// this is prose for a settings window rather than a breadcrumb.
    public var title: String {
        switch self {
        case .optionReturn:  "⌥ Return"
        case .commandEscape: "⌘ Escape"
        case .controlReturn: "⌃ Return"
        case .controlSpace:  "⌃ Space"
        case .optionSpace:   "⌥ Space"
        }
    }

    /// What this choice costs, said plainly. Every leader shadows *something*; a settings
    /// window that pretends otherwise is how a user ends up confused a week later.
    public var note: String? {
        switch self {
        case .optionReturn:  "Shadows Xcode's Focus Editor Pane, which ⌥RET w replaces."
        case .commandEscape: "Unclaimed in Xcode."
        case .controlReturn: "Unclaimed in Xcode."
        case .controlSpace:  "Often taken by an input-source switcher."
        case .optionSpace:   "Alfred and Raycast use this by default."
        }
    }

    public static func choice(for event: KeyEvent) -> LeaderChoice? {
        allCases.first { $0.event == event }
    }
}
