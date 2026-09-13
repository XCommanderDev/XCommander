import Foundation

/// Whether the picker shows a preview pane, as a setting.
///
/// **Three states, not a switch.** The pane sits to the *right* of the results — the
/// convention every other editor's picker follows — so the panel grows wider to make room, and
/// an Xcode window narrow enough cannot take it without the panel running off the side. A plain
/// on/off would force a choice between letting that happen and silently disobeying the setting.
/// `auto` makes the geometry guard the documented behaviour instead of a surprise, which is why
/// it is the default.
public enum PreviewMode: String, Hashable, Sendable, CaseIterable {
    case on, auto, off

    public static let `default` = PreviewMode.auto

    /// Room the panel needs beyond its own width, so it never sits edge to edge with the
    /// window it is centred on.
    public static let margin: Double = 80

    /// Whether to show a pane in a window of this width.
    ///
    /// - Parameter windowWidth: Xcode's window, or the screen when Xcode will not say.
    /// - Parameter panelWidth: what the panel would become with the pane attached.
    public func showsPreview(inWindowOfWidth windowWidth: Double,
                             panelWidth: Double) -> Bool {
        switch self {
        case .off: false
        case .on: true
        case .auto: windowWidth >= panelWidth + Self.margin
        }
    }

    /// How it reads in the popup.
    public var title: String {
        switch self {
        case .on: "Always"
        case .auto: "When the window is tall enough"
        case .off: "Never"
        }
    }

    /// What the choice costs, said plainly — the same discipline as `LeaderChoice.note`.
    public var note: String? {
        switch self {
        case .on: "The picker may run past the edge of a narrow Xcode window."
        case .auto: nil
        case .off: "Search results show the matched line only."
        }
    }
}
