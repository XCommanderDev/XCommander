import AppKit
import ApplicationServices
import AutographeCore

/// Reading one of Xcode's toolbar popups.
///
/// An `AXMenuButton` has no children until its menu is open, so there is no way to learn
/// what is inside one without opening it. That makes this unavoidably intrusive — the menu
/// appears on screen and is then cancelled — which is why nothing calls it on a keystroke
/// path and `xcmdr` keeps it behind its own subcommand.
public enum PopupReader {

    public struct Item {
        public var title: String
        public var identifier: String
    }

    /// Press an item inside a toolbar popup, by identifier.
    ///
    /// Shares `open` with `read` on purpose: the app presses and `xcmdr` inspects, and if
    /// those walked the toolbar differently then `xcmdr popups` would be reporting on a
    /// control the app never touches.
    ///
    /// Blocking, and not for a keystroke path — the caller runs it off the main actor. If
    /// the wanted item is not there the menu is cancelled, so a miss never leaves a popup
    /// hanging over the editor.
    @discardableResult
    public static func press(button description: String, identifier: String, pid: pid_t,
                             attempts: Int = 25) -> Bool {
        guard let (button, menu) = open(button: description, pid: pid, attempts: attempts) else {
            return false
        }
        _ = button
        guard let hit = MenuScanner.children(of: menu).first(where: {
            MenuScanner.string($0, kAXIdentifierAttribute) == identifier
        }) else {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            return false
        }
        return AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success
    }

    /// Open the named toolbar popup, read it, and close it again.
    public static func read(button description: String, pid: pid_t,
                            attempts: Int = 25) -> [Item] {
        guard let (_, menu) = open(button: description, pid: pid, attempts: attempts) else { return [] }
        let items = MenuScanner.children(of: menu).compactMap { item -> Item? in
            let title = MenuScanner.string(item, kAXTitleAttribute) ?? ""
            guard !title.isEmpty else { return nil }
            return Item(title: title,
                        identifier: MenuScanner.string(item, kAXIdentifierAttribute) ?? "")
        }
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        return items
    }

    /// Find the toolbar control, ask its menu to open, and wait for it.
    ///
    /// Observed at about 50 ms to appear; the budget is ten times that, and it gives up
    /// rather than hanging.
    public static func open(button description: String, pid: pid_t,
                            attempts: Int = 25) -> (button: AXUIElement, menu: AXUIElement)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              CFGetTypeID(window!) == AXUIElementGetTypeID() else { return nil }

        var button: AXUIElement?
        func descend(_ element: AXUIElement, _ depth: Int) {
            if button != nil || depth > 4 { return }
            for child in MenuScanner.children(of: element) {
                if MenuScanner.string(child, kAXDescriptionAttribute) == description {
                    button = child; return
                }
                descend(child, depth + 1)
            }
        }
        descend(window as! AXUIElement, 0)
        guard let button,
              AXUIElementPerformAction(button, kAXShowMenuAction as CFString) == .success
        else { return nil }

        for _ in 0..<attempts {
            usleep(20_000)
            if let menu = MenuScanner.children(of: button).first(where: {
                MenuScanner.string($0, kAXRoleAttribute) == kAXMenuRole as String
            }) { return (button, menu) }
        }
        return nil
    }
}
