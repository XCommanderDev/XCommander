import Foundation

/// The leaders a user is allowed to choose.
///
/// **A closed list, not a key recorder, and that is the design.** A leader is swallowed while
/// Xcode is frontmost, so a leader that can be typed as text arms a sequence by accident and
/// the next word runs a command — the defect that moved the default off `⇧Space`.
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

    /// What this choice costs, said plainly. A settings window that presents five options as
    /// though they were free is how a user ends up confused a week later.
    ///
    /// Anything said here about *Xcode* must agree with `shadows`, which a test checks against
    /// a real capture. The first version of this note said `⌥Return` shadowed Focus Editor
    /// Pane; in Xcode 27 that command is `⌃⇧⌘Return` and nothing in the menu bar uses
    /// `⌥Return` — and `⌃Space`, the one leader that *does* hide an Xcode command, did not
    /// mention it. Prose about another app's shortcuts goes stale on its release schedule,
    /// not ours, so it is checked rather than trusted.
    public var note: String? {
        switch self {
        case .optionReturn:  "Unclaimed in Xcode's menus."
        case .commandEscape: "Unclaimed in Xcode's menus."
        case .controlReturn: "Unclaimed in Xcode's menus."
        case .controlSpace:  "Hides Xcode's Show Completions. Often taken by an input-source switcher too."
        case .optionSpace:   "Alfred and Raycast use this by default."
        }
    }

    /// The Xcode menu items this leader hides, by identifier.
    ///
    /// **A claim about Xcode, made checkable.** A leader is swallowed while Xcode is in front,
    /// so any menu item on the same chord becomes unreachable. That is acceptable when it is
    /// known and said — it is not acceptable when a new Xcode quietly moves a command onto the
    /// leader. `unexpectedShadows(in:)` compares this list with a catalogue; the tests run it
    /// against the checked-in capture, and the change report runs it against every new build.
    ///
    /// Menu bar only. Xcode also has text-editing bindings that are not menu items, and
    /// nothing here can see those.
    public var shadows: [String] {
        switch self {
        case .controlSpace: ["complete:"]
        case .optionReturn, .commandEscape, .controlReturn, .optionSpace: []
        }
    }

    /// Where this leader and a catalogue disagree: items on the chord that `shadows` does not
    /// declare, and declared items that are no longer on it. Both mean the note is wrong.
    public func unexpectedShadows(in catalogue: MenuCatalogue)
        -> (undeclared: [MenuEntry], stale: [String]) {
        let onChord = catalogue.entries(withShortcut: event)
        let found = Set(onChord.map(\.identifier))
        return (onChord.filter { !shadows.contains($0.identifier) },
                shadows.filter { !found.contains($0) })
    }

    public static func choice(for event: KeyEvent) -> LeaderChoice? {
        allCases.first { $0.event == event }
    }
}
