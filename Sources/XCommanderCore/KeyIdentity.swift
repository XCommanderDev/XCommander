import Foundation

/// Turning a physical keypress into the key a *binding* names.
///
/// The rule: **a character key is identified by the character it produces.** A binding for
/// `/` must fire wherever `/` lives on the user's keyboard — unshifted on QWERTY, Shift and
/// the `:` key on French AZERTY, somewhere else again on a Vietnamese or Arabic layout. The
/// user types `⌥RET /`; how their hardware gets there is not our business.
///
/// So Shift is **folded into the character** rather than stored beside it. Storing it
/// separately is what made `⌥RET /` dead on AZERTY: the tap reported `:` plus Shift, and
/// nothing was bound to that.
///
/// The exception is a **chord** — Control, Option or Command. There the modifier is the
/// point and the character is just the key you hold it with, so the *unshifted* character
/// identifies it and every modifier stays explicit. That is also how macOS itself matches
/// menu key equivalents.
public enum KeyIdentity {

    /// - Parameters:
    ///   - base: the character this key produces with no modifiers.
    ///   - shifted: the character it produces with Shift.
    ///   - special: set when the key has no character at all (space, escape, arrows).
    ///   - modifiers: what was actually held down.
    public static func event(base: Character?,
                             shifted: Character?,
                             special: SpecialKey?,
                             modifiers: Modifiers) -> KeyEvent? {
        // A key with no character keeps its modifiers: the leader is ⌥RET, and Return
        // has no shifted form to fold anything into.
        if let special { return KeyEvent(special, modifiers) }

        let isChord = modifiers.contains(.control)
            || modifiers.contains(.option)
            || modifiers.contains(.command)

        if isChord {
            guard let base else { return nil }
            return KeyEvent(.character(base), modifiers)
        }

        // Plain, or Shift alone: the character on the screen is the identity.
        let produced = modifiers.contains(.shift) ? (shifted ?? base) : base
        guard let produced else { return nil }
        return KeyEvent(.character(produced), [])
    }
}
