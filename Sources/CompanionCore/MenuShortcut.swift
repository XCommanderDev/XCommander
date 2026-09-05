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
        var modifiers = Modifiers()
        if mask & ModifierMask.noCommand == 0 { modifiers.insert(.command) }
        if mask & ModifierMask.shift != 0 { modifiers.insert(.shift) }
        if mask & ModifierMask.option != 0 { modifiers.insert(.option) }
        if mask & ModifierMask.control != 0 { modifiers.insert(.control) }
        return KeyEvent(.character(character), modifiers)
    }
}
