import Foundation

/// Decoding a macOS menu item's shortcut as Accessibility reports it.
///
/// Pure, and in Core, because it is small, fiddly, and was wrong once in a way no type
/// checker would catch: it fired Analyze instead of Build. Logic that can be got subtly
/// wrong belongs where a test can pin it.
public enum MenuShortcut {

    /// `AXMenuItemCmdModifiers` is a mask over an *implicit* Command key.
    public struct ModifierMask {
        public static let shift = 1
        public static let option = 2
        public static let control = 4
        /// Set when the shortcut does **not** include Command.
        public static let noCommand = 8
    }

    /// Turn the character and mask Accessibility reports into a key event.
    ///
    /// - Parameters:
    ///   - character: `AXMenuItemCmdChar`. Letters arrive upper-cased for display
    ///     regardless of whether Shift is part of the shortcut.
    ///   - mask: `AXMenuItemCmdModifiers`.
    ///
    /// Letters are lower-cased and the mask is treated as the only statement about Shift.
    /// Punctuation is left exactly as reported, because there the case *is* the character:
    /// on French AZERTY `⌘%` genuinely means Command with the `%` character, which is typed
    /// as Shift on the `ù` key, and lower-casing it would name a different key entirely.
    public static func decode(character: Character, mask: Int) -> KeyEvent {
        var character = character
        if character.isLetter, let lower = character.lowercased().first {
            character = lower
        }
        return KeyEvent(.character(character), modifiers(from: mask))
    }

    /// The same, for the items whose shortcut is not a character at all.
    ///
    /// `AXMenuItemCmdChar` reports arrows and function keys as the private-use scalars
    /// AppKit defines: `Debug > Step Over` arrives as `U+F709`, not as anything a person
    /// typed. The character-only entry point above takes that literally and hands back a
    /// `KeyEvent` for a key no keyboard has — which then gets displayed in the which-key
    /// panel and, worse, synthesised. On Xcode 27.0, 38 of the 752 menu items report such a
    /// shortcut: 30 name a key Core has — the arrows under `Jump to …Counterpart` and
    /// `Editor > Code Folding`, plus Return, Tab and Delete — and 8 do not.
    ///
    /// Nil means "this item's shortcut cannot be said in Core's vocabulary" — now only
    /// dictation's microphone, since the function row was added for the debugger. The caller
    /// is then sent down the `AXPress` path: a millisecond instead of forty microseconds,
    /// and right instead of wrong.
    public static func decode(character: Character, mask: Int, virtualKey: Int?) -> KeyEvent? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        if let special = specialKey(for: scalar.value) {
            return KeyEvent(.special(special), modifiers(from: mask))
        }
        // Fall through only for an ordinary character. On AZERTY the menu reports `Ù` and
        // `§` as themselves and those must survive, so the test is the private-use floor
        // rather than anything about the Latin-1 range.
        guard scalar.value >= 0x20, scalar.value < 0xF700 else { return nil }
        return decode(character: character, mask: mask)
    }

    /// `AXMenuItemCmdVirtualKey` is captured alongside these but deliberately not consulted:
    /// a keycode means different characters on different layouts, which is the whole reason
    /// `Key` stores a character. It is in the snapshot so that a future reader has it.
    private static func specialKey(for scalar: UInt32) -> SpecialKey? {
        switch scalar {
        case 0xF700: .up
        case 0xF701: .down
        case 0xF702: .left
        case 0xF703: .right
        case 0xF729: .home
        case 0xF72B: .end
        case 0xF72C: .pageUp
        case 0xF72D: .pageDown
        case 0x08, 0x7F: .delete
        case 0x09: .tab
        case 0x0D: .return
        case 0x1B: .escape
        case 0x20: .space
        // `NSF1FunctionKey` onwards, contiguous from U+F704.
        case 0xF704...0xF70F: functionKey(Int(scalar - 0xF704) + 1)
        default: nil
        }
    }

    private static func functionKey(_ n: Int) -> SpecialKey? {
        switch n {
        case 1: .f1
        case 2: .f2
        case 3: .f3
        case 4: .f4
        case 5: .f5
        case 6: .f6
        case 7: .f7
        case 8: .f8
        case 9: .f9
        case 10: .f10
        case 11: .f11
        case 12: .f12
        default: nil
        }
    }

    /// The mask is a statement about an *implicit* Command key, so it is read the same way
    /// wherever a shortcut is decoded.
    private static func modifiers(from mask: Int) -> Modifiers {
        var modifiers = Modifiers()
        if mask & ModifierMask.noCommand == 0 { modifiers.insert(.command) }
        if mask & ModifierMask.shift != 0 { modifiers.insert(.shift) }
        if mask & ModifierMask.option != 0 { modifiers.insert(.option) }
        if mask & ModifierMask.control != 0 { modifiers.insert(.control) }
        return modifiers
    }
}
