import AppKit

/// An opaque-ish backing for the overlay panels.
///
/// It exists because the panels sit over Xcode, whose theme is independent of the system
/// appearance: a heavily translucent panel takes its contrast from whatever is behind it,
/// and in light mode over a dark editor that came out as a grey haze.
///
/// It **draws** rather than setting `layer.backgroundColor` on purpose. A `CGColor` is
/// resolved once, at the moment you assign it, so a dynamic system colour baked into a
/// layer is frozen at whatever the appearance was when the view was built — the panel then
/// stays light after the user switches to dark, which is exactly the bug this replaced.
/// Drawing resolves the colour on every pass, and AppKit redraws on an appearance change.
final class PanelBackingView: NSView {
    var cornerRadius: CGFloat = 12
    var alpha: CGFloat = 0.82

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    /// Belt and braces: ask for a redraw when the effective appearance changes, rather than
    /// relying on AppKit to decide this view needs one.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
