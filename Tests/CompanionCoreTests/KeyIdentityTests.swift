import Testing
@testable import CompanionCore

/// The bug these exist for: on French AZERTY `/` is Shift and the `:` key, so `⇧SPC /`
/// arrived as `:` plus Shift, nothing was bound to that, and the picker never opened. The
/// same binding has to fire on every layout — the user types `⇧SPC /` and how their
/// hardware produces `/` is not our business.
@Suite("Key identity across layouts")
struct KeyIdentityTests {

    /// The same *logical* key on four layouts, described as the hardware reports it.
    private func press(base: Character?, shifted: Character?, _ modifiers: Modifiers) -> KeyEvent? {
        KeyIdentity.event(base: base, shifted: shifted, special: nil, modifiers: modifiers)
    }

    @Test("US: slash is unshifted and identifies as slash")
    func slashOnUS() {
        #expect(press(base: "/", shifted: "?", []) == KeyEvent("/"))
    }

    /// The reported bug, as a test.
    @Test("French AZERTY: Shift and the colon key is still slash")
    func slashOnAZERTY() {
        #expect(press(base: ":", shifted: "/", [.shift]) == KeyEvent("/"))
    }

    @Test("German QWERTZ: Shift-7 is still slash")
    func slashOnQWERTZ() {
        #expect(press(base: "7", shifted: "/", [.shift]) == KeyEvent("/"))
    }

    /// Every layout that can type `/` at all reaches the same binding.
    @Test("one binding, four layouts, same event", arguments: [
        (Character(":"), Character("/"), Modifiers.shift),   // French AZERTY
        (Character("/"), Character("?"), Modifiers()),       // US QWERTY
        (Character("7"), Character("/"), Modifiers.shift),   // German QWERTZ
        (Character("-"), Character("/"), Modifiers.shift),   // Vietnamese / others
    ])
    func slashEverywhere(base: Character, shifted: Character, modifiers: Modifiers) {
        #expect(press(base: base, shifted: shifted, modifiers) == KeyEvent("/"))
    }

    @Test("an upper-case letter is the upper-case character, not a letter plus Shift")
    func upperCaseLetters() {
        #expect(press(base: "s", shifted: "S", [.shift]) == KeyEvent("S"))
        #expect(press(base: "s", shifted: "S", []) == KeyEvent("s"))
    }

    /// AZERTY's digit row is shifted, so `⇧SPC T 0` has to work there too.
    @Test("digits that need Shift still identify as digits")
    func shiftedDigits() {
        #expect(press(base: "à", shifted: "0", [.shift]) == KeyEvent("0"))
    }

    /// In a chord the modifier is the point, so the *unshifted* character identifies the
    /// key and every modifier stays explicit. This is how macOS matches menu equivalents.
    @Test("a chord keeps its modifiers and uses the base character")
    func chordsKeepModifiers() {
        #expect(press(base: "b", shifted: "B", [.command]) == KeyEvent("b", [.command]))
        #expect(press(base: "b", shifted: "B", [.command, .shift]) == KeyEvent("b", [.command, .shift]))
        #expect(press(base: "a", shifted: "A", [.control]) == KeyEvent("a", [.control]))
        #expect(press(base: "x", shifted: "X", [.option]) == KeyEvent("x", [.option]))
    }

    /// Otherwise `⌥b` would arrive as `∫` and the picker's Ctrl chords would arrive as
    /// control characters, and neither would ever match.
    @Test("a chord is not folded into the character it would produce")
    func chordsAreNotFolded() {
        let event = press(base: "b", shifted: "B", [.option])
        #expect(event?.key == .character("b"))
        #expect(event?.modifiers == [.option])
    }

    /// Space, Escape and the arrows have no shifted form to fold anything into, and the
    /// leader is ⇧SPC, so they keep their modifiers.
    @Test("special keys keep their modifiers, which is what makes the leader work")
    func specialKeysKeepModifiers() {
        let leader = KeyIdentity.event(base: nil, shifted: nil, special: .space, modifiers: [.shift])
        #expect(leader == KeyEvent(.space, [.shift]))
        #expect(leader == DefaultKeymap.leader)

        let escape = KeyIdentity.event(base: nil, shifted: nil, special: .escape, modifiers: [])
        #expect(escape == .escape)
    }

    @Test("a key with no character at all yields nothing rather than a wrong guess")
    func deadKeys() {
        #expect(press(base: nil, shifted: nil, []) == nil)
        #expect(press(base: nil, shifted: nil, [.command]) == nil)
    }

    /// A key whose shifted form the layout does not report falls back to the base rather
    /// than dropping the keystroke.
    @Test("a missing shifted form falls back to the base character")
    func missingShiftedForm() {
        #expect(press(base: "a", shifted: nil, [.shift]) == KeyEvent("a"))
    }
}
