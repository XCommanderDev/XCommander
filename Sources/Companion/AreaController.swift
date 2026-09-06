import AppKit
import ApplicationServices
import CompanionCore
import os

/// Putting the keyboard **into** a part of Xcode's window that the menu bar cannot target.
///
/// This class is deliberately one job, because that is all the menu bar cannot already do.
/// `View > Navigators >` selects any navigator and reveals the pane if it is hidden; the
/// inspector panes and `Debug Area > Activate Console` are ordinary menu items too, and the
/// last of those even moves the keyboard for us. What the menu has no item for is "focus this
/// list": `Navigate > Move Focus to Next Area` only *cycles* the areas, and from the editor it
/// took three presses to arrive — fine as `w a`, useless as a way to say "go there".
///
/// Two areas qualify, and the reasons they are the only two are worth keeping. The
/// **inspector** is not here because its content is a form of text fields and popup buttons,
/// so "focus it" names nothing you could then use the arrow keys on. The **console** is not
/// here because the menu already focuses it.
///
/// Setting `AXFocused` on the navigator's outline does it in one step, and it is real
/// keyboard focus: with it set, the arrow keys walk the tree (seen moving the selection
/// `FuzzyMatcher.swift` → `Keymap.swift`). It is the same technique `PaneController` uses to
/// focus an editor pane.
///
/// **A note on how this was nearly built wrong.** An earlier version of this file also drove
/// navigator *selection* by pressing the selector buttons, on the evidence that the menu
/// items were inert under `AXPress`. They are not. The probe that produced that evidence did
/// not bring Xcode to the front first, and Xcode's menus do not respond when it is not
/// frontmost — the same trap that makes a menu dump look empty. Two features' worth of
/// machinery rested on one broken experiment, and deleting it left this.
@MainActor
final class AreaController {

    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "navigator")

    init() {}

    /// Put the keyboard into an area, so the arrow keys walk it.
    ///
    /// False when the area is not on screen, which is what a hidden pane looks like.
    @discardableResult
    func focus(_ area: XcodeArea) -> Bool {
        guard let element = element(for: area) else {
            log.notice("no \(area.rawValue, privacy: .public) to focus — the pane is probably hidden")
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString,
                                            kCFBooleanTrue) == .success
    }

    private func element(for area: XcodeArea) -> AXUIElement? {
        switch area {
        case .navigator:
            return navigatorOutline()
        case .variables:
            // The debug area's variables list names itself, and unlike the navigator's
            // outline its identifier is a generated `_NS:` number, so the description is the
            // only stable handle.
            return firstDescendant { Self.string($0, kAXDescriptionAttribute) == "variables view" }
        }
    }

    // MARK: - finding the outline

    /// **Each navigator has its own outline with its own identifier** — `project navigator`,
    /// `issue navigator`, and so on — so this matches the shared suffix rather than one
    /// spelling. The leftmost-outline fallback covers any navigator that names itself
    /// differently: the navigator is by definition the left-hand pane.
    private func navigatorOutline() -> AXUIElement? {
        firstDescendant { element in
            Self.string(element, kAXRoleAttribute) == "AXOutline"
                && (Self.string(element, kAXIdentifierAttribute) ?? "").hasSuffix("navigator")
        } ?? leftmostOutline()
    }

    private func leftmostOutline() -> AXUIElement? {
        var best: (element: AXUIElement, x: CGFloat)?
        walk { element in
            guard Self.string(element, kAXRoleAttribute) == "AXOutline",
                  let frame = Self.frame(of: element) else { return }
            if best == nil || frame.minX < best!.x { best = (element, frame.minX) }
        }
        return best?.element
    }

    private func firstDescendant(where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var hit: AXUIElement?
        walk { element in
            if hit == nil, matches(element) { hit = element }
        }
        return hit
    }

    private func walk(_ visit: (AXUIElement) -> Void) {
        guard let root = window() else { return }
        func descend(_ element: AXUIElement, _ depth: Int) {
            if depth > 14 { return }
            for child in Self.children(of: element) {
                visit(child)
                descend(child, depth + 1)
            }
        }
        descend(root, 0)
    }

    private func window() -> AXUIElement? {
        guard let xcode = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first else { return nil }
        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win!) == AXUIElementGetTypeID() else { return nil }
        return (win as! AXUIElement)
    }

    // MARK: - AX helpers

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &v) == .success
        else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success
        else { return nil }
        return v as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
