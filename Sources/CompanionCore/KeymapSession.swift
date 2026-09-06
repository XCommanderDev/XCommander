import Foundation

/// What the event tap should do with a key, and what the overlay should show.
public enum SessionOutcome: Hashable, Sendable {
    /// Not ours. Let it through to Xcode untouched.
    case passThrough
    /// A sequence started or advanced. Swallow the key; show this panel after the delay.
    case awaiting(WhichKeyPanel)
    /// Swallow the key and run this.
    /// The id of the command to run. The app looks it up in the registry.
    case fired(String)
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
    /// Nothing resolved the sequence for `timeout` seconds, so it gave up.
    case timedOut
}

/// The modal state machine: idle, or partway through a sequence.
///
/// Pure and synchronous. The tap calls `press` and gets a decision back in the same
/// breath, which is what keeps the callback in the microseconds — see the latency table
/// in `SPIKE-REPORT.md`.
public struct KeymapSession: Sendable {
    public let leader: KeyEvent
    public private(set) var keymap: Keymap
    public private(set) var registry: CommandRegistry
    /// Supplies each command's live Xcode shortcut for the panel's dimmed right column.
    /// A closure because it depends on the running Xcode, which Core knows nothing about.
    public var shortcutProvider: @Sendable (Command) -> String? = { _ in nil }
    /// The keys pressed since the leader. Empty while idle.
    public private(set) var pending: [KeyEvent] = []
    public private(set) var isActive = false

    /// How long an armed sequence waits for its next key before giving up.
    ///
    /// This is **not** what protects you from a mis-typed leader: that keystroke and the
    /// letter after it are milliseconds apart, so no timeout worth having would separate
    /// them. Choosing a leader that cannot be typed as text is what does that job. What
    /// this stops is the other case — a sequence you started and then abandoned, which
    /// would otherwise stay armed indefinitely and read whatever you typed on your return
    /// as a command.
    ///
    /// Ten seconds because the panel is on screen after `overlayDelay`, so the user has
    /// feedback throughout and the only thing being bounded is a sequence they have
    /// forgotten about. Short enough to matter, long enough to read thirty rows.
    public var timeout: TimeInterval = 10

    /// When the last key of the current sequence arrived. `nil` while idle.
    private var lastPressAt: TimeInterval?

    public init(leader: KeyEvent, keymap: Keymap, registry: CommandRegistry) {
        self.leader = leader
        self.keymap = keymap
        self.registry = registry
    }

    /// The breadcrumb shown in the panel: the leader plus everything pressed since.
    public var breadcrumb: String {
        ([leader] + pending).map(\.display).joined(separator: " ")
    }

    public mutating func press(_ event: KeyEvent,
                               at now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> SessionOutcome {
        // An expired sequence is treated as though it had never been armed, so this key is
        // passed through to Xcode rather than swallowed. Swallowing it would be the same
        // defect in a smaller form: a keystroke the user meant for their file, eaten.
        if isActive, let last = lastPressAt, now - last >= timeout { reset() }

        guard isActive else {
            guard event == leader else { return .passThrough }
            isActive = true
            pending = []
            lastPressAt = now
            return .awaiting(WhichKeyPanel(breadcrumb: breadcrumb, rows: rows(at: [])))
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
            lastPressAt = now
            return .awaiting(WhichKeyPanel(breadcrumb: breadcrumb, rows: rows(at: [])))
        }

        let candidate = pending + [event]
        switch keymap.entry(at: candidate) {
        case .some(.command(let commandID)):
            reset()
            return .fired(commandID)
        case .some(.group):
            pending = candidate
            lastPressAt = now
            return .awaiting(WhichKeyPanel(breadcrumb: breadcrumb,
                                           rows: rows(at: pending)))
        case .none:
            reset()
            return .cancelled(reason: .unbound(event))
        }
    }

    /// Called by the app's timer. Ends the sequence only if nothing has arrived since,
    /// so a key that landed between the timer being scheduled and firing wins the race.
    /// Returns `nil` when there is nothing to do, which is the ordinary case.
    public mutating func expireIfIdle(at now: TimeInterval = Date().timeIntervalSinceReferenceDate)
        -> SessionOutcome? {
        guard isActive, let last = lastPressAt, now - last >= timeout else { return nil }
        reset()
        return .cancelled(reason: .timedOut)
    }

    /// Everything that ends a sequence without a keypress: a mouse click, an app switch,
    /// the tap being disabled. §8 question 2 — every abandonment path resets the same way.
    public mutating func abandon() -> SessionOutcome? {
        guard isActive else { return nil }
        reset()
        return .cancelled(reason: .abandoned)
    }

    private func rows(at sequence: [KeyEvent]) -> [WhichKeyRow] {
        keymap.rows(at: sequence, in: registry, shortcut: shortcutProvider)
    }

    private mutating func reset() {
        isActive = false
        pending = []
        lastPressAt = nil
    }
}
