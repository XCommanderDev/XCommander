import CoreGraphics
import CompanionCore

/// The edge where CoreGraphics stops and CompanionCore begins.
///
/// Core deliberately knows nothing about `CGEventFlags` or virtual keycodes, so every
/// conversion lives here and is the only place that has to be right.
@MainActor
enum EventBridge {

    nonisolated static func modifiers(from flags: CGEventFlags) -> Modifiers {
        var m = Modifiers()
        if flags.contains(.maskCommand)   { m.insert(.command) }
        if flags.contains(.maskShift)     { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskControl)   { m.insert(.control) }
        return m
    }

    nonisolated static func flags(from modifiers: Modifiers) -> CGEventFlags {
        var f = CGEventFlags()
        if modifiers.contains(.command) { f.insert(.maskCommand) }
        if modifiers.contains(.shift)   { f.insert(.maskShift) }
        if modifiers.contains(.option)  { f.insert(.maskAlternate) }
        if modifiers.contains(.control) { f.insert(.maskControl) }
        return f
    }

    /// Turn a tap event into the value type the keymap speaks.
    ///
    /// The character is read from the *unmodified* layout on purpose. With Option held,
    /// `⌥space` would otherwise arrive as a non-breaking space and `⌥b` as `∫`, and the
    /// keymap would never match. What the user means is the key they pressed.
    static func keyEvent(keyCode: CGKeyCode, flags: CGEventFlags) -> KeyEvent? {
        let mods = modifiers(from: flags)
        if let special = KeyboardLayout.special(forKeyCode: keyCode) {
            return KeyEvent(special, mods)
        }
        guard let c = KeyboardLayout.character(forKeyCode: keyCode) else { return nil }
        return KeyEvent(.character(c), mods)
    }
}
