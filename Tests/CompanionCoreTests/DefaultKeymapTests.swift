import Testing
@testable import CompanionCore

@Suite("Shipped keymap and status")
struct DefaultKeymapTests {

    /// `DefaultKeymap.build()` uses `try!`, so a conflict introduced while editing the
    /// table would crash at launch. This test finds it in the suite instead.
    @Test("the shipped keymap builds without conflicts")
    func buildsCleanly() {
        let map = DefaultKeymap.build()
        #expect(map.rows(at: []).isEmpty == false)
    }

    @Test("every top-level entry is a titled group")
    func topLevelGroups() {
        let rows = DefaultKeymap.build().rows(at: [])
        #expect(rows.map(\.key) == ["b", "f", "n", "r", "s", "t"])
        // A key-path shorthand here trips the #expect macro: it rewrites the call into a
        // form that loses the non-throwing signature. A closure avoids it.
        #expect(rows.allSatisfy { $0.isGroup })
        #expect(rows.first { $0.key == "b" }?.label == "+build")
    }

    @Test("every binding is reachable and lands on a command")
    func everyBindingResolves() {
        let map = DefaultKeymap.build()
        for (sequence, command) in DefaultKeymap.bindings {
            guard case .some(.command(let found)) = map.entry(at: sequence) else {
                Issue.record("\(sequence.map(\.display).joined(separator: " ")) does not resolve")
                continue
            }
            #expect(found.id == command.id)
        }
    }

    @Test("command ids are unique")
    func uniqueIDs() {
        let ids = DefaultKeymap.bindings.map(\.1.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Upper case in the binding table means Shift, which is easy to get wrong and
    /// invisible when it is.
    @Test("an upper-case literal is the lower-case key with Shift")
    func upperCaseMeansShift() {
        let e: KeyEvent = "S"
        #expect(e == KeyEvent("s", [.shift]))
        #expect(e.display == "⇧s")
    }

    @Test("the leader is Shift-Space and renders as ⇧SPC")
    func leader() {
        #expect(DefaultKeymap.leader == KeyEvent(.space, [.shift]))
        #expect(DefaultKeymap.leader.display == "⇧SPC")
    }

    @Test("status is derived, and permission outranks everything")
    func status() {
        #expect(CompanionStatus.derive(hasAccessibility: false, secureInputActive: true,
                                       xcodeFrontmost: true) == .needsAccessibility)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: true,
                                       xcodeFrontmost: true) == .pausedBySecureInput)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: false,
                                       xcodeFrontmost: false) == .idle)
        #expect(CompanionStatus.derive(hasAccessibility: true, secureInputActive: false,
                                       xcodeFrontmost: true) == .armed)
    }
}
