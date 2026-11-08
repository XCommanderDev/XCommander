import AppKit
import XCommanderCore

/// Every colour the overlays draw with, in one place.
///
/// Xcode's *Default (Dark)* editor colours for anything that is code or structure, and a warm
/// yellow for the keys — the one colour that is not Xcode's, borrowed from the way Doom's
/// Monokai Pro sets keys apart from the words they run.
///
/// **Literals, on a panel that is always dark.** The first version resolved system colours so
/// the panels followed light and dark, and it read as a system popover pasted over an editor.
/// These panels belong to the editor they sit on, not to the system around it — and since
/// Xcode's theme is independent of the system appearance anyway, following the system never
/// bought the match it seemed to. A fixed dark panel has the same contrast over any editor,
/// which is the property the backing view was always there to guarantee.
enum Theme {

    // MARK: Surfaces

    static let whichKeyBackground = rgb(0x1A1A1F, alpha: 0.94)
    static let pickerBackground = rgb(0x26262C, alpha: 0.94)
    static let hairline = NSColor.white.withAlphaComponent(0.08)
    static let rule = NSColor.white.withAlphaComponent(0.14)
    static let selection = rgb(0x0A84FF)
    static let focusLine = rgb(0x0A84FF, alpha: 0.16)
    static let searchMark = rgb(0xFFD60A, alpha: 0.30)

    // MARK: Text

    static let text = rgb(0xDFDFE1)
    static let textStrong = NSColor.white
    static let textDim = rgb(0x98989F)
    static let textFaint = rgb(0x5F5F67)

    // MARK: The which-key panel

    static let key = rgb(0xD9C97C)
    static let breadcrumb = rgb(0xFF7AB2)
    static let group = rgb(0xDABAFF)

    // MARK: Xcode "Default (Dark)"

    static let keyword = rgb(0xFF7AB2)
    static let string = rgb(0xFF8170)
    static let number = rgb(0xD9C97C)
    static let comment = rgb(0x7F8C98)
    static let typeName = rgb(0xDABAFF)
    static let declaration = rgb(0x6BDFFF)
    static let projectName = rgb(0x78C2B3)
    static let attribute = rgb(0xCC9768)
    static let preprocessor = rgb(0xFFA14F)

    /// A badge's tint. The families keep Xcode's grouping — types purple, callables blue, values
    /// teal — in Xcode's own shades, and our commands take the key yellow, so a command in the
    /// palette and a key in the which-key panel read as the same kind of thing.
    static func colour(for tint: IconTint) -> NSColor {
        switch tint {
        case .purple: typeName
        case .blue:   declaration
        case .teal:   projectName
        case .green:  rgb(0x30D158)
        case .orange: preprocessor
        case .pink:   keyword
        case .grey:   comment
        case .accent: key
        }
    }

    /// One colour per syntax role, the ones Xcode's dark theme uses for the same role.
    static func colour(for role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword:    keyword
        case .string:     string
        case .number:     number
        case .comment:    comment
        case .docComment: comment
        case .typeName:   typeName
        case .attribute:  attribute
        case .plain:      text
        }
    }

    /// Hex as written in the design, so a colour can be checked against it by eye.
    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}
