import Foundation

/// The modifier keys, as a set rather than a bitmask of someone else's numbering.
///
/// Deliberately not `CGEventFlags`: Core has no CoreGraphics, so the keymap can be
/// built and tested without a window server. The event tap converts at the edge.
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift   = Modifiers(rawValue: 1 << 1)
    public static let option  = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)

    /// Xcode's own order, so a rendered shortcut reads the way the menu does.
    public var display: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key that has no character, and therefore no dependence on the keyboard layout.
public enum SpecialKey: String, Hashable, Sendable, CaseIterable {
    case escape, space, tab, `return`, delete
    case left, right, up, down
    case home, end, pageUp, pageDown

    public var display: String {
        switch self {
        case .escape: "ESC"
        case .space:  "SPC"
        case .tab:    "TAB"
        case .return: "RET"
        case .delete: "DEL"
        case .left:   "←"
        case .right:  "→"
        case .up:     "↑"
        case .down:   "↓"
        case .home:   "↖"
        case .end:    "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        }
    }
}

/// A key is either a character or one of the special keys.
///
/// Storing the *character* rather than a virtual keycode is the whole point. Xcode
/// reports its shortcuts as characters in the user's current layout (on French AZERTY
/// `Product > Stop` comes back as `;`, not `.`), and a keycode that means `b` on one
/// layout means something else on another. The keycode is resolved from the live
/// layout at the moment we post, and nowhere else.
public enum Key: Hashable, Sendable {
    case character(Character)
    case special(SpecialKey)

    public var display: String {
        switch self {
        case .character(let c): String(c)
        case .special(let s): s.display
        }
    }
}

/// One keypress: a key plus the modifiers held with it.
public struct KeyEvent: Hashable, Sendable {
    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ character: Character, _ modifiers: Modifiers = []) {
        self.init(.character(character), modifiers)
    }

    public init(_ special: SpecialKey, _ modifiers: Modifiers = []) {
        self.init(.special(special), modifiers)
    }

    /// How this key appears in the which-key panel and the breadcrumb.
    public var display: String { modifiers.display + key.display }

    public static let escape = KeyEvent(.escape)
}
