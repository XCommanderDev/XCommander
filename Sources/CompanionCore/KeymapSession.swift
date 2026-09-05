import Foundation

/// What the event tap should do with a key, and what the overlay should show.
public enum SessionOutcome: Hashable, Sendable {
    /// Not ours. Let it through to Xcode untouched.
    case passThrough
    /// A sequence started or advanced. Swallow the key; show this panel after the delay.
    case awaiting(WhichKeyPanel)
    /// Swallow the key and run this.
    case fired(Command)
    /// Swallow the key and hide the panel. `Esc`, or a key that is not in the current node.
    case cancelled(reason: CancelReason)

    /// Whether the tap should eat this key rather than pass it to Xcode.
    public var swallowsKey: Bool {
        if case .passThrough = self { return false }
        return true
    }
}

public enum CancelReason: Hashable, Sendable {
    case escape
    /// A key that the current node does not bind. Swallowed rather than passed on, so a
    /// stray keystroke never lands in the user's source file.
    case unbound(KeyEvent)
    /// Xcode stopped being frontmost, the mouse was clicked, the tap was interrupted.
    case abandoned
}

/// The modal state machine: idle, or partway through a sequence.
///
/// Pure and synchronous. The tap calls `press` and gets a decision back in the same
/// breath, which is what keeps the callback in the microseconds — see the latency table
/// in `SPIKE-REPORT.md`.
public struct KeymapSession: Sendable {
    public let leader: KeyEvent
    public private(set) var keymap: Keymap
    /// The keys pressed since the leader. Empty while idle.
    public private(set) var pending: [KeyEvent] = []
    public private(set) var isActive = false

    public init(leader: KeyEvent, keymap: Keymap) {
        self.leader = leader
        self.keymap = keymap
    }

    /// The breadcrumb shown in the panel: the leader plus everything pressed since.
    public var breadcrumb: String {
        ([leader] + pending).map(\.display).joined(separator: " ")
    }

    public mutating func press(_ event: KeyEvent) -> SessionOutcome {
        guard isActive else {
            guard event == leader else { return .passThrough }
            isActive = true
            pending = []
            return .awaiting(WhichKeyPanel(breadcrumb: breadcrumb, rows: keymap.rows(at: [])))
        }

        // Universal Esc. Works from any depth, which is the one binding a modal system
        // must never make conditional.
        if event == .escape {
            reset()
            return .cancelled(reason: .escape)
        }

        // Pressing the leader again while a sequence is open restarts it rather than
        // cancelling. Cheaper than Esc-then-leader, and it is what the muscle expects.
        if event == leader {
            pending = []
            return .awaiting(WhichKeyPanel(breadcrumb: breadcrumb, rows: keymap.rows(at: [])))
        }

        let candidate = pending + [event]
        switch keymap.entry(at: candidate) {
        case .some(.command(let command)):
            reset()
            return .fired(command)
        case .some(.group):
            pending = candidate
            return .awaiting(WhichKeyPanel(breadcrumb: breadcrumb,
                                           rows: keymap.rows(at: pending)))
        case .none:
            reset()
            return .cancelled(reason: .unbound(event))
        }
    }

    /// Everything that ends a sequence without a keypress: a mouse click, an app switch,
    /// the tap being disabled. §8 question 2 — every abandonment path resets the same way.
    public mutating func abandon() -> SessionOutcome? {
        guard isActive else { return nil }
        reset()
        return .cancelled(reason: .abandoned)
    }

    private mutating func reset() {
        isActive = false
        pending = []
    }
}
