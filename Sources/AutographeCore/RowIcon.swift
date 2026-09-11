import Foundation

/// The colour a row's badge uses, named rather than specified.
///
/// Core has no AppKit, so it cannot hold an `NSColor` — and it should not want to. Naming
/// the *role* keeps the palette in one place in the app, which is also what lets it adapt
/// to light and dark without Core knowing either exists.
public enum IconTint: String, Hashable, Sendable, CaseIterable {
    case purple, blue, teal, green, orange, pink, grey, accent
}

/// A small badge, in the shape Xcode uses in its own completion list: a rounded square
/// holding a letter or two, tinted by what the thing is.
public struct RowIcon: Hashable, Sendable {
    public let glyph: String
    public let tint: IconTint

    public init(_ glyph: String, _ tint: IconTint) {
        self.glyph = glyph
        self.tint = tint
    }

    // Kinds of row, each with the letter Xcode would use where there is one.
    public static let command   = RowIcon("⌘", .accent)
    public static let menuItem  = RowIcon("≡", .grey)
    public static let file      = RowIcon("ƒ", .blue)
    public static let buffer    = RowIcon("◧", .teal)
    public static let searchHit = RowIcon("⌕", .green)
    public static let transform = RowIcon("↹", .pink)
    public static let pane      = RowIcon("◫", .teal)
    public static let picker    = RowIcon("⌥", .accent)
    public static let destination = RowIcon("▶", .orange)
    public static let navigator = RowIcon("◨", .purple)

    /// Symbols follow Xcode's completion badges: a letter for the kind, coloured by family.
    /// Types are purple, callables blue, values teal — the same grouping Xcode uses, so the
    /// list reads the way its own completion list does.
    public static func symbol(_ kind: SymbolKind) -> RowIcon {
        switch kind {
        case .struct:        RowIcon("S", .purple)
        case .class:         RowIcon("C", .purple)
        case .enum:          RowIcon("E", .orange)
        case .protocol:      RowIcon("Pr", .purple)
        case .extension:     RowIcon("Ex", .purple)
        case .typeAlias:     RowIcon("T", .purple)
        case .function:      RowIcon("f", .blue)
        case .instanceMethod, .classMethod, .staticMethod: RowIcon("M", .blue)
        case .constructor:   RowIcon("I", .blue)
        case .variable:      RowIcon("V", .teal)
        case .instanceProperty, .classProperty, .staticProperty: RowIcon("P", .teal)
        case .enumConstant:  RowIcon("c", .orange)
        case .macro:         RowIcon("#", .pink)
        case .field:         RowIcon("P", .teal)
        default:             RowIcon("?", .grey)
        }
    }

    /// The badge for one of our own commands, from what it does. A palette full of
    /// identical icons is no better than none, so each family gets its own.
    public static func forAction(_ action: CommandAction) -> RowIcon {
        switch action {
        case .menuPath:  .menuItem
        case .shortcut:  .command
        case .transform: .transform
        case .pane:      .pane
        case .focus: .navigator
        case .picker:    .picker
        case .companion: .command
        }
    }
}
