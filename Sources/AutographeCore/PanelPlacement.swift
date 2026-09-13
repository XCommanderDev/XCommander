import Foundation

/// Where the picker panel sits.
///
/// It is centred on Xcode's window and pinned near the top, the way Open Quickly and every
/// other command palette sits. The part that needs arithmetic — and therefore tests — is what
/// happens when that puts it somewhere it cannot go.
///
/// **The panel is a fixed width for the life of a presentation** (see
/// `PickerOverlay.previewWidth`): it must not resize under the hand using it. So when Xcode is
/// resized *while the picker is open*, the panel keeps its size and re-centres — which means a
/// window narrowed to less than the panel's width leaves the panel overhanging it. That is
/// fine, and intended. What is not fine is the panel leaving the **screen**, which is what
/// centring on a window near a screen edge does if nothing stops it.
public enum PanelPlacement {

    /// Distance the panel keeps from the screen's edges when it has to be pushed back on.
    public static let screenInset: Double = 8

    /// The panel's frame, centred on `target` and pinned `topInset` below its top edge, then
    /// clamped so it stays on `screen`.
    ///
    /// - Parameter target: Xcode's window, in Cocoa coordinates (y grows upward).
    /// - Parameter screen: the visible frame to stay within.
    public static func frame(width: Double, height: Double, topInset: Double,
                             centredOn target: PaneRect, within screen: PaneRect) -> PaneRect {
        var x = target.midX - width / 2
        var y = target.maxY - height - topInset

        // A panel wider than the screen cannot be clamped into it — centre it instead, so it
        // overhangs evenly rather than being shoved against one edge.
        if width >= screen.width - screenInset * 2 {
            x = screen.midX - width / 2
        } else {
            x = min(max(x, screen.minX + screenInset), screen.maxX - width - screenInset)
        }
        if height >= screen.height - screenInset * 2 {
            y = screen.midY - height / 2
        } else {
            y = min(max(y, screen.minY + screenInset), screen.maxY - height - screenInset)
        }
        return PaneRect(x: x, y: y, width: width, height: height)
    }
}
