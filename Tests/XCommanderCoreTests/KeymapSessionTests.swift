import Testing
@testable import XCommanderCore

/// The session is what the event tap actually asks, so these tests are written as
/// sequences of presses with the tap's question in mind: swallow it, or pass it on?
@Suite("Keymap session")
struct KeymapSessionTests {

    private let leader = KeyEvent(.return, [.option])

    private func session() throws -> KeymapSession {
        var registry = CommandRegistry()
        registry.register(.menu("make.build", "build", MenuRef("buildActiveRunContext:")))
        registry.register(Command(id: "quit", title: "quit", action: .companion("quit")))

        var map = Keymap()
        let titles: [[KeyEvent]: String] = [[KeyEvent("m")]: "make"]
        try map.bind([KeyEvent("m"), KeyEvent("m")], to: "make.build", groupTitles: titles)
        try map.bind([KeyEvent("q")], to: "quit")
        return KeymapSession(leader: leader, keymap: map, registry: registry)
    }

    @Test("keys are passed through until the leader is pressed")
    func idlePassesThrough() throws {
        var s = try session()
        #expect(s.press(KeyEvent("m")) == .passThrough)
        #expect(s.press(KeyEvent("x", [.command])) == .passThrough)
        #expect(s.isActive == false)
    }

    @Test("the leader opens the root panel and is swallowed")
    func leaderOpens() throws {
        var s = try session()
        let outcome = s.press(leader)
        guard case .awaiting(let panel) = outcome else {
            Issue.record("expected awaiting, got \(outcome)"); return
        }
        #expect(outcome.swallowsKey)
        #expect(panel.breadcrumb == "⌥RET")
        #expect(panel.rows.map(\.key) == ["m", "q"])
    }

    @Test("a group key refines the panel and extends the breadcrumb")
    func groupRefines() throws {
        var s = try session()
        _ = s.press(leader)
        guard case .awaiting(let panel) = s.press(KeyEvent("m")) else {
            Issue.record("expected awaiting"); return
        }
        #expect(panel.breadcrumb == "⌥RET m")
        #expect(panel.rows.map(\.key) == ["m"])
    }

    @Test("a leaf fires the command and ends the session")
    func fires() throws {
        var s = try session()
        _ = s.press(leader)
        _ = s.press(KeyEvent("m"))
        guard case .fired(let id) = s.press(KeyEvent("m")) else {
            Issue.record("expected fired"); return
        }
        #expect(id == "make.build")
        #expect(s.isActive == false)
        #expect(s.pending.isEmpty)
    }

    @Test("a one-key command fires straight from the root")
    func firesFromRoot() throws {
        var s = try session()
        _ = s.press(leader)
        guard case .fired(let id) = s.press(KeyEvent("q")) else {
            Issue.record("expected fired"); return
        }
        #expect(id == "quit")
    }

    /// The one binding a modal system must never make conditional.
    @Test("Esc cancels from the root and from inside a group")
    func escapeCancels() throws {
        var s = try session()
        _ = s.press(leader)
        #expect(s.press(.escape) == .cancelled(reason: .escape))
        #expect(s.isActive == false)

        _ = s.press(leader)
        _ = s.press(KeyEvent("m"))
        #expect(s.press(.escape) == .cancelled(reason: .escape))
        #expect(s.isActive == false)
    }

    /// If an unbound key were passed through, a mistyped sequence would drop a stray
    /// character into the user's source file. It is swallowed instead.
    @Test("an unbound key cancels and is still swallowed")
    func unboundKeySwallowed() throws {
        var s = try session()
        _ = s.press(leader)
        let outcome = s.press(KeyEvent("z"))
        #expect(outcome == .cancelled(reason: .unbound(KeyEvent("z"))))
        #expect(outcome.swallowsKey)
        #expect(s.isActive == false)
    }

    @Test("pressing the leader again restarts the sequence rather than cancelling it")
    func leaderRestarts() throws {
        var s = try session()
        _ = s.press(leader)
        _ = s.press(KeyEvent("m"))
        guard case .awaiting(let panel) = s.press(leader) else {
            Issue.record("expected awaiting"); return
        }
        #expect(panel.breadcrumb == "⌥RET")
        #expect(s.pending.isEmpty)
    }

    /// Every abandonment path has to reset the same way.
    @Test("abandoning mid-sequence resets, and does nothing when idle")
    func abandon() throws {
        var s = try session()
        #expect(s.abandon() == nil)

        _ = s.press(leader)
        _ = s.press(KeyEvent("m"))
        #expect(s.abandon() == .cancelled(reason: .abandoned))
        #expect(s.isActive == false)
        #expect(s.press(KeyEvent("m")) == .passThrough)
    }

    @Test("after firing, the next key is passed through again")
    func returnsToIdle() throws {
        var s = try session()
        _ = s.press(leader)
        _ = s.press(KeyEvent("q"))
        #expect(s.press(KeyEvent("q")) == .passThrough)
    }

    // MARK: - the sequence timeout

    /// The clock is a parameter rather than `Date()`, so these run instantly and
    /// deterministically. A test that has to sleep for ten seconds to prove a ten-second
    /// timeout is a test nobody runs.

    @Test("an armed sequence expires, and the key that finds it expired reaches Xcode")
    func expiresAndPassesThrough() throws {
        var s = try session()
        _ = s.press(leader, at: 0)
        #expect(s.isActive)

        // `m` would normally open the make group. Arriving after the timeout it should
        // instead find no session at all, and — the part that matters — be passed through
        // rather than swallowed. Eating the user's keystroke would be the same defect the
        // leader change exists to remove, in a smaller form.
        #expect(s.press(KeyEvent("m"), at: 11) == .passThrough)
        #expect(s.isActive == false)
    }

    @Test("the bound is on idle time, so a slow deliberate sequence is never cut off")
    func timeoutIsIdleNotTotal() throws {
        var s = try session()
        _ = s.press(leader, at: 0)
        // Nine seconds to decide, then nine more: eighteen seconds in total, but never ten
        // idle, so the sequence survives and fires.
        guard case .awaiting = s.press(KeyEvent("m"), at: 9) else {
            Issue.record("the make group should still have been open at t=9")
            return
        }
        #expect(s.press(KeyEvent("m"), at: 18) == .fired("make.build"))
    }

    @Test("expireIfIdle cancels an abandoned sequence")
    func expiryFromTheTimer() throws {
        var s = try session()
        _ = s.press(leader, at: 0)
        #expect(s.expireIfIdle(at: 10) == .cancelled(reason: .timedOut))
        #expect(s.isActive == false)
    }

    @Test("expireIfIdle loses the race to a key that arrived first")
    func expiryLosesTheRace() throws {
        var s = try session()
        _ = s.press(leader, at: 0)
        _ = s.press(KeyEvent("m"), at: 9)          // the timer for t=10 is already scheduled
        #expect(s.expireIfIdle(at: 10) == nil)     // but the clock was reset, so it does nothing
        #expect(s.isActive)
    }

    @Test("expireIfIdle does nothing when the session is idle to begin with")
    func expiryWhenNothingIsArmed() throws {
        var s = try session()
        #expect(s.expireIfIdle(at: 1_000) == nil)
    }

    /// **The limit of this feature, asserted so nobody mistakes it for the fix.**
    ///
    /// A mis-typed leader and the letter after it are milliseconds apart, so no timeout
    /// worth having separates them: at 40 ms the sequence is still very much alive and the
    /// word still runs a command. What actually removes this failure is a leader that
    /// cannot be produced as text, which is why the default moved to `⌥RET`.
    @Test("a timeout does not protect against a mis-typed leader — only the key choice does")
    func timeoutDoesNotSaveAMistypedLeader() throws {
        var s = try session()
        _ = s.press(leader, at: 0)
        #expect(s.press(KeyEvent("m"), at: 0.04) != .passThrough)
        #expect(s.press(KeyEvent("m"), at: 0.08) == .fired("make.build"))
    }
}
