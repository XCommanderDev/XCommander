import AppKit

/// The opaque backing for the overlay panels.
///
/// It exists because the panels sit over Xcode, whose theme is independent of the system
/// appearance: a heavily translucent panel takes its contrast from whatever is behind it, and
/// in light mode over a dark editor that came out as a grey haze. A near-opaque fill makes the
/// contrast a property of the panel, and the material around it still supplies the blur.
///
/// Each panel passes its own colour from `Theme`. It **draws** rather than setting
/// `layer.backgroundColor`, which also keeps working if a colour here is ever a dynamic system
/// colour again: a `CGColor` is resolved once, when it is assigned, and never follows an
/// appearance change after that.
final class PanelBackingView: NSView {
    var colour: NSColor = Theme.whichKeyBackground
    var cornerRadius: CGFloat = 12

    override func draw(_ dirtyRect: NSRect) {
        colour.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}
