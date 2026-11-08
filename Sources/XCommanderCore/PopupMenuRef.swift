import Foundation

/// A command that lives in a toolbar popup rather than in the menu bar.
///
/// **Xcode 27 did not delete editor splitting; it moved it out of reach of the menu bar.**
/// `File > New > Editor Pane On Right` and `Editor Pane Below` are gone from the menus, and
/// the audit was right to say so — but the actions behind them are alive and well in the
/// toolbar's *Add Editor* popup, under the same names they always had:
///
///     Tab                     newTab:
///     Editor Pane On Right    newEditorAreaSplitOnRight:
///     Editor Pane Below       newEditorAreaSplitBelow:
///
/// So the lesson is not "Apple removed a feature" but "a menu bar is not the whole of an
/// app". A popup is a worse place to reach from the outside — the menu has to be opened,
/// waited for, and pressed, which costs a few milliseconds and blinks on screen — so this is
/// deliberately a separate action type rather than something `MenuRef` pretends to do. When
/// a command can be had from the menu bar, it should be.
public struct PopupMenuRef: Hashable, Sendable, Codable {
    /// The toolbar control's `AXDescription`, as Xcode sets it: `Add Editor`.
    public var button: String
    /// The item inside, named the same way everything else is.
    public var item: MenuRef

    public init(button: String, item: MenuRef) {
        self.button = button
        self.item = item
    }

    public init(button: String, identifier: String) {
        self.init(button: button, item: MenuRef(identifier))
    }

    /// Xcode's *Add Editor* popup, which is where all three editor-creating commands went.
    public static func addEditor(_ identifier: String) -> PopupMenuRef {
        PopupMenuRef(button: "Add Editor", identifier: identifier)
    }
}
