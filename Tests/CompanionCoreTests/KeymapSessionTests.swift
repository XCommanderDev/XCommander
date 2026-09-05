import Testing
@testable import CompanionCore

/// The session is what the event tap actually asks, so these tests are written as
/// sequences of presses with the tap's question in mind: swallow it, or pass it on?
@Suite("Keymap session")
struct KeymapSessionTests {

    private let leader = KeyEvent(.space, [.shift])

    private func session() throws -> KeymapSession {
        var map = Keymap()
        let titles: [[KeyEvent]: String] = [[KeyEvent("b")]: "build"]
        try map.bind([KeyEvent("b"), KeyEvent("b")],
                     to: .menu("build.build", "build", ["Product", "Build"]),
                     groupTitles: titles)
        try map.bind([KeyEvent("q")],
                     to: Command(id: "quit", title: "quit", action: .companion("quit")))
        return KeymapSession(leader: leader, keymap: map)
    }

    @Test("keys are passed through until the leader is pressed")
    func idlePassesThrough() throws {
        var s = try session()
        #expect(s.press(KeyEvent("b")) == .passThrough)
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
        #expect(panel.breadcrumb == "⇧SPC")
        #expect(panel.rows.map(\.key) == ["b", "q"])
    }

    @Test("a group key refines the panel and extends the breadcrumb")
    func groupRefines() throws {
        var s = try session()
        _ = s.press(leader)
        guard case .awaiting(let panel) = s.press(KeyEvent("b")) else {
            Issue.record("expected awaiting"); return
        }
        #expect(panel.breadcrumb == "⇧SPC b")
        #expect(panel.rows.map(\.key) == ["b"])
    }

    @Test("a leaf fires the command and ends the session")
    func fires() throws {
        var s = try session()
        _ = s.press(leader)
        _ = s.press(KeyEvent("b"))
        guard case .fired(let command) = s.press(KeyEvent("b")) else {
            Issue.record("expected fired"); return
        }
        #expect(command.id == "build.build")
        #expect(s.isActive == false)
        #expect(s.pending.isEmpty)
    }

    @Test("a one-key command fires straight from the root")
    func firesFromRoot() throws {
        var s = try session()
        _ = s.press(leader)
        guard case .fired(let c) = s.press(KeyEvent("q")) else {
            Issue.record("expected fired"); return
        }
        #expect(c.id == "quit")
    }

    /// The one binding a modal system must never make conditional.
    @Test("Esc cancels from the root and from inside a group")
    func escapeCancels() throws {
        var s = try session()
        _ = s.press(leader)
        #expect(s.press(.escape) == .cancelled(reason: .escape))
        #expect(s.isActive == false)

        _ = s.press(leader)
        _ = s.press(KeyEvent("b"))
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
        _ = s.press(KeyEvent("b"))
        guard case .awaiting(let panel) = s.press(leader) else {
            Issue.record("expected awaiting"); return
        }
        #expect(panel.breadcrumb == "⇧SPC")
        #expect(s.pending.isEmpty)
    }

    /// §8 question 2: every abandonment path has to reset the same way.
    @Test("abandoning mid-sequence resets, and does nothing when idle")
    func abandon() throws {
        var s = try session()
        #expect(s.abandon() == nil)

        _ = s.press(leader)
        _ = s.press(KeyEvent("b"))
        #expect(s.abandon() == .cancelled(reason: .abandoned))
        #expect(s.isActive == false)
        #expect(s.press(KeyEvent("b")) == .passThrough)
    }

    @Test("after firing, the next key is passed through again")
    func returnsToIdle() throws {
        var s = try session()
        _ = s.press(leader)
        _ = s.press(KeyEvent("q"))
        #expect(s.press(KeyEvent("q")) == .passThrough)
    }
}
