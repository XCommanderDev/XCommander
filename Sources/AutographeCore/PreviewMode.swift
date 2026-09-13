import Foundation

/// Whether the picker shows a preview pane, as a setting.
///
/// **Three states, not a switch.** The panel grows downward to make room for the pane, and an
/// Xcode window short enough — a laptop screen, a window tiled to half the height — cannot
/// take the taller panel without it running off the bottom. A plain on/off would force a
/// choice between letting that happen and silently disobeying the setting. `auto` makes the
/// geometry guard the documented behaviour instead of a surprise, which is why it is the
/// default.
public enum PreviewMode: String, Hashable, Sendable, CaseIterable {
    case on, auto, off

    public static let `default` = PreviewMode.auto

    /// Room the panel needs beyond its own height: the gap it sits below the window's top
    /// edge, plus enough that it does not touch the bottom.
    public static let margin: Double = 160

    /// Whether to show a pane in a window of this height.
    ///
    /// - Parameter windowHeight: Xcode's window, or the screen when Xcode will not say.
    /// - Parameter panelHeight: what the panel would become with the pane attached.
    public func showsPreview(inWindowOfHeight windowHeight: Double,
                             panelHeight: Double) -> Bool {
        switch self {
        case .off: false
        case .on: true
        case .auto: windowHeight >= panelHeight + Self.margin
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
        case .on: "The picker may run past the bottom of a short Xcode window."
        case .auto: nil
        case .off: "Search and symbol results show the matched line only."
        }
    }
}
