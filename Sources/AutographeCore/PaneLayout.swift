import Foundation

/// A rectangle, without dragging CoreGraphics into Core.
public struct PaneRect: Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// One editor pane.
public struct Pane: Hashable, Sendable {
    public let index: Int
    public let frame: PaneRect
    public let isFocused: Bool
    public init(index: Int, frame: PaneRect, isFocused: Bool) {
        self.index = index; self.frame = frame; self.isFocused = isFocused
    }
}

/// Screen coordinates here are Accessibility's: y grows **downward**.
public enum PaneDirection: Hashable, Sendable {
    case left, right, up, down

    public var title: String {
        switch self {
        case .left: "focus left"
        case .right: "focus right"
        case .up: "focus up"
        case .down: "focus down"
        }
    }
}

/// Choosing the pane to move to.
///
/// Xcode can only cycle: `Move Focus to Next Editor Pane`, and an interactive chooser. Vim
/// and Emacs users reach for a *direction* — `⌃w l` goes right whatever the layout is — and
/// that is missing, so we compute it from the panes' geometry.
///
/// The rule, which is the one vim uses: consider only panes on the correct side; prefer
/// those that actually overlap the current pane on the other axis, so a split above a
/// neighbour never steals a sideways move; then take the closest.
public enum PaneLayout {

    /// Panes touching within this many points count as adjacent rather than overlapping.
    private static let tolerance = 2.0

    public static func target(from focused: Pane, direction: PaneDirection,
                              among panes: [Pane]) -> Pane? {
        let others = panes.filter { $0.index != focused.index }
        guard !others.isEmpty else { return nil }

        let candidates = others.filter { isOn(direction, of: focused, candidate: $0) }
        guard !candidates.isEmpty else { return nil }

        // Panes that share an edge-span with the current one, which is nearly always what
        // the user means. Only if none do is a diagonal jump better than nothing.
        let aligned = candidates.filter { overlaps($0, focused, along: direction) }
        let pool = aligned.isEmpty ? candidates : aligned

        return pool.min { a, b in
            let da = distance(from: focused, to: a, direction: direction)
            let db = distance(from: focused, to: b, direction: direction)
            if da != db { return da < db }
            // Same distance: prefer the one whose centre is nearest on the other axis, so
            // a column of equal candidates resolves to the one straight ahead.
            return perpendicular(focused, a, direction) < perpendicular(focused, b, direction)
        }
    }

    private static func isOn(_ direction: PaneDirection, of focused: Pane, candidate: Pane) -> Bool {
        switch direction {
        case .left:  candidate.frame.maxX <= focused.frame.minX + tolerance
        case .right: candidate.frame.minX >= focused.frame.maxX - tolerance
        case .up:    candidate.frame.maxY <= focused.frame.minY + tolerance
        case .down:  candidate.frame.minY >= focused.frame.maxY - tolerance
        }
    }

    /// Overlap on the axis perpendicular to the move.
    private static func overlaps(_ a: Pane, _ b: Pane, along direction: PaneDirection) -> Bool {
        switch direction {
        case .left, .right:
            a.frame.minY < b.frame.maxY - tolerance && b.frame.minY < a.frame.maxY - tolerance
        case .up, .down:
            a.frame.minX < b.frame.maxX - tolerance && b.frame.minX < a.frame.maxX - tolerance
        }
    }

    private static func distance(from: Pane, to: Pane, direction: PaneDirection) -> Double {
        switch direction {
        case .left:  from.frame.minX - to.frame.maxX
        case .right: to.frame.minX - from.frame.maxX
        case .up:    from.frame.minY - to.frame.maxY
        case .down:  to.frame.minY - from.frame.maxY
        }
    }

    private static func perpendicular(_ a: Pane, _ b: Pane, _ direction: PaneDirection) -> Double {
        switch direction {
        case .left, .right: abs(a.frame.midY - b.frame.midY)
        case .up, .down:    abs(a.frame.midX - b.frame.midX)
        }
    }
}

/// Splitter arithmetic.
///
/// An `AXSplitter`'s `AXValue` moves the divider one point per unit, measured against the
/// pane before it: setting 846 → 646 took a 552-point pane down to 352. Every number below
/// falls out of that, which is why it can be computed rather than guessed.
public enum PaneResize {

    /// Never leave a pane too small to be a pane.
    ///
    /// Xcode's own minimum is larger than a token gap — asking a splitter for a position
    /// that would squeeze the other editor below it is refused outright with
    /// `kAXErrorIllegalArgument`, not clamped — so this errs generously.
    public static let minimumExtent = 260.0

    /// Values to try, most ambitious first, stepping back toward where the divider already
    /// is. A split view refuses an out-of-range position rather than clamping it, and the
    /// exact limit depends on what is inside the panes, so the honest approach is to ask
    /// for what we want and settle for what is allowed.
    public static func ladder(from current: Int, to target: Int) -> [Int] {
        guard target != current else { return [] }
        let steps = [1.0, 0.75, 0.5, 0.25]
        var seen = Set<Int>()
        return steps.compactMap { fraction in
            let value = current + Int((Double(target - current) * fraction).rounded())
            guard value != current, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    /// The value that makes two adjacent panes the same size.
    public static func balanced(currentValue: Int, before: Double, after: Double) -> Int {
        let target = (before + after) / 2
        return currentValue + Int((target - before).rounded())
    }

    /// Give the focused pane as much room as the other can spare.
    public static func maximized(currentValue: Int, before: Double, after: Double,
                                 focusIsBefore: Bool) -> Int {
        let total = before + after
        let target = focusIsBefore ? total - minimumExtent : minimumExtent
        return currentValue + Int((target - before).rounded())
    }

    /// Grow or shrink the focused pane, refusing to squeeze its neighbour out of existence.
    public static func resized(currentValue: Int, before: Double, after: Double,
                               focusIsBefore: Bool, by delta: Double) -> Int {
        let change = focusIsBefore ? delta : -delta
        let target = min(max(before + change, minimumExtent), before + after - minimumExtent)
        return currentValue + Int((target - before).rounded())
    }
}
