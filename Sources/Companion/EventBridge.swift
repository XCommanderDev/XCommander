import CoreGraphics
import XCommanderCore

/// The edge where CoreGraphics stops and XCommanderCore begins.
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
    /// The policy lives in `KeyIdentity`, in Core, where it is tested: this only supplies
    /// what the current layout produces for the key.
    static func keyEvent(keyCode: CGKeyCode, flags: CGEventFlags) -> KeyEvent? {
        let pair = KeyboardLayout.characters(forKeyCode: keyCode)
        return KeyIdentity.event(base: pair.base,
                                 shifted: pair.shifted,
                                 special: KeyboardLayout.special(forKeyCode: keyCode),
                                 modifiers: modifiers(from: flags))
    }
}
