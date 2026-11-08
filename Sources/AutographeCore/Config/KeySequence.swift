import Foundation

/// Reading and writing the key syntax a configuration file uses.
///
/// **It is exactly what the which-key panel shows.** `KeySequence.render` is
/// `sequence.map(\.display).joined(separator: " ")`, and `parse` is its inverse — so a user
/// can read `m m` off the panel, or `⌥RET` off the settings window, and type that into the
/// file. No second notation to learn, no table in the documentation mapping one to the other,
/// and no way for the two to drift apart, because a round-trip test asserts every shipped
/// binding survives the trip.
///
/// This is worth insisting on. The obvious alternative — inventing `C-x` or `alt+return`
/// because it is easier to type on a US keyboard — creates a vocabulary the app itself never
/// speaks, and every error message then has to translate.
public enum KeySequence {

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case unknownKey(String)
        case danglingModifier(String)

        public var description: String {
            switch self {
            case .empty:
                "a key sequence cannot be empty"
            case .unknownKey(let token):
                "'\(token)' is not a key. Use one character, or a name like "
                    + "RET, SPC, TAB, ESC, DEL — with modifiers written ⌃ ⌥ ⇧ ⌘"
            case .danglingModifier(let token):
                "'\(token)' is modifiers with no key after them"
            }
        }
    }

    /// `"m m"` → two presses. `"⌥RET"` → one. Space is written `SPC`, because the separator
    /// between presses is a space and a format cannot have it both ways.
    public static func parse(_ text: String) throws -> [KeyEvent] {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { throw ParseError.empty }
        return try tokens.map(parseKey)
    }

    public static func parseKey(_ token: String) throws -> KeyEvent {
        var rest = Substring(token)
        var modifiers: Modifiers = []
        loop: while let first = rest.first {
            switch first {
            case "⌃": modifiers.insert(.control)
            case "⌥": modifiers.insert(.option)
            case "⇧": modifiers.insert(.shift)
            case "⌘": modifiers.insert(.command)
            default: break loop
            }
            rest = rest.dropFirst()
        }

        guard !rest.isEmpty else { throw ParseError.danglingModifier(token) }

        if let special = SpecialKey.allCases.first(where: { $0.display == rest }) {
            return KeyEvent(special, modifiers)
        }
        guard rest.count == 1, let character = rest.first else {
            throw ParseError.unknownKey(token)
        }
        return KeyEvent(.character(character), modifiers)
    }

    /// The form a file would write, and the form the panel already draws.
    public static func render(_ sequence: [KeyEvent]) -> String {
        sequence.map(\.display).joined(separator: " ")
    }
}
