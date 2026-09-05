import AppKit
import ApplicationServices
import CompanionCore

/// What we need to know about Xcode. Behind a protocol because it is the least testable
/// part of the system and the most likely to break across Xcode versions.
@MainActor
protocol XcodeContext {
    var isRunning: Bool { get }
    var isFrontmost: Bool { get }
    /// Xcode's focused window in AX coordinates (top-left origin), or nil if it will not say.
    func focusedWindowFrame() -> CGRect?
    /// Look up a menu item by path. Nil if the path is not currently in the menu.
    func menuItem(at path: [String]) -> MenuItemInfo?
    /// Press a menu item over Accessibility. ~1 ms once the element is resolved.
    @discardableResult func press(_ item: MenuItemInfo) -> Bool
    /// Re-read the menu bar. Expensive (~750 ms), so it is explicit rather than automatic.
    func refreshMenuIndex()
    /// Every menu item Xcode currently offers, for the command palette.
    func allMenuItems() -> [MenuItemInfo]
    /// Every indexed menu item under a prefix, for the menu-slice pickers.
    /// `Product > Destination` alone is 80 items with 3 shortcuts.
    func menuItems(under prefix: [String]) -> [MenuItemInfo]
    /// The file open in the focused editor, from the window's `AXDocument`.
    func documentURL() -> URL?
    /// The selected text, or nil when there is no editor focused.
    func selectedText() -> String?
    /// Replace the selection. Xcode's own undo reverts this.
    @discardableResult func replaceSelection(with text: String) -> Bool
    /// Grow an empty selection to cover the whole line, so a transform with nothing
    /// selected acts on the line the cursor is in — which is what every editor does.
    @discardableResult func selectCurrentLineIfEmpty() -> Bool
}

struct MenuItemInfo {
    var path: [String]
    var element: AXUIElement
    /// The shortcut Xcode currently has for this item, already translated into Core's
    /// vocabulary. Nil when the item has no shortcut, which is the tier-2 case.
    var shortcut: KeyEvent?
    var isEnabled: Bool
}

/// The real thing, over `AXUIElement`.
@MainActor
final class AccessibilityXcodeContext: XcodeContext {

    private var app: AXUIElement?
    private var pid: pid_t?
    private var index: [[String]: MenuItemInfo] = [:]

    /// The AX default is 1.5 s. A blocked Xcode main thread is a normal state, not an
    /// error — a macOS privacy sheet caused exactly that during the spikes — and waiting
    /// a second and a half for an answer we are only using to place a window is not a
    /// trade worth making.
    private static let messagingTimeout: Float = 0.25

    private var runningXcode: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first
    }

    var isRunning: Bool { runningXcode != nil }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dt.Xcode"
    }

    /// Rebind to Xcode's current process, dropping any cached menu elements if the pid
    /// changed. Menu `AXUIElement`s belong to a process and are meaningless after a relaunch.
    private func appElement() -> AXUIElement? {
        guard let running = runningXcode else {
            app = nil; pid = nil; index = [:]
            return nil
        }
        if running.processIdentifier != pid {
            pid = running.processIdentifier
            app = AXUIElementCreateApplication(running.processIdentifier)
            index = [:]
            if let app { AXUIElementSetMessagingTimeout(app, Self.messagingTimeout) }
        }
        return app
    }

    func focusedWindowFrame() -> CGRect? {
        guard let app = appElement() else { return nil }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win!) == AXUIElementGetTypeID() else { return nil }
        let window = win as! AXUIElement
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Look a menu item up by path.
    ///
    /// Exact match first, then a **prefix match on the last component**. Some of Xcode's
    /// menu titles carry the current context: `File > Close “main.swift”` names the open
    /// file, so no static path can ever match it. A command that wants such an item names
    /// the stable part (`Close “`) and relies on this fallback. Exact always wins, so this
    /// cannot hijack a path that really exists.
    func menuItem(at path: [String]) -> MenuItemInfo? {
        if index.isEmpty { refreshMenuIndex() }
        if let exact = index[path] { return exact }
        guard let wanted = path.last, path.count >= 2 else { return nil }
        let parent = Array(path.dropLast())
        let candidates = index.values.filter {
            $0.path.count == path.count
                && Array($0.path.dropLast()) == parent
                && ($0.path.last ?? "").hasPrefix(wanted)
        }
        // Deterministic when more than one matches, rather than whichever the dictionary
        // happened to yield first.
        return candidates.min { $0.path.last! < $1.path.last! }
    }

    func allMenuItems() -> [MenuItemInfo] {
        if index.isEmpty { refreshMenuIndex() }
        // The Apple menu is the system's, not Xcode's, and nobody reaches for "About This
        // Mac" from a code editor's command palette.
        return index.values
            .filter { $0.path.first != "Apple" }
            .sorted { $0.path.joined() < $1.path.joined() }
    }

    func menuItems(under prefix: [String]) -> [MenuItemInfo] {
        if index.isEmpty { refreshMenuIndex() }
        return index.values
            .filter { $0.path.count == prefix.count + 1 && Array($0.path.prefix(prefix.count)) == prefix }
            .sorted { $0.path.last! < $1.path.last! }
    }

    func documentURL() -> URL? {
        guard let app = appElement() else { return nil }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win!) == AXUIElementGetTypeID() else { return nil }
        guard let path = Self.string(win as! AXUIElement, kAXDocumentAttribute) else { return nil }
        return URL(string: path) ?? URL(fileURLWithPath: path)
    }

    // MARK: - the editor's text

    /// Xcode's source editor is an `AXTextArea` whose `AXValue`, `AXSelectedText` and
    /// `AXSelectedTextRange` are all settable. That is what lets us do text transforms with
    /// no Source Editor Extension — which is just as well, since Xcode 26 appears not to
    /// load those any more.
    private func focusedTextArea() -> AXUIElement? {
        guard let app = appElement() else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              CFGetTypeID(focused!) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard Self.string(element, kAXRoleAttribute) == "AXTextArea" else { return nil }
        return element
    }

    func selectedText() -> String? {
        guard let editor = focusedTextArea() else { return nil }
        return Self.string(editor, kAXSelectedTextAttribute)
    }

    @discardableResult
    func replaceSelection(with text: String) -> Bool {
        guard let editor = focusedTextArea() else { return false }
        return AXUIElementSetAttributeValue(editor, kAXSelectedTextAttribute as CFString,
                                            text as CFTypeRef) == .success
    }

    @discardableResult
    func selectCurrentLineIfEmpty() -> Bool {
        guard let editor = focusedTextArea() else { return false }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success else { return false }
        var range = CFRange()
        AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
        guard range.length == 0 else { return true }
        guard let value = Self.string(editor, kAXValueAttribute) else { return false }

        // Work in UTF-16, because that is what an AX range counts.
        let units = Array(value.utf16)
        let caret = min(max(range.location, 0), units.count)
        var start = caret
        while start > 0, units[start - 1] != 10 { start -= 1 }
        var end = caret
        while end < units.count, units[end] != 10 { end += 1 }
        guard end > start else { return false }

        var line = CFRange(location: start, length: end - start)
        guard let lineValue = AXValueCreate(.cfRange, &line) else { return false }
        return AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString,
                                            lineValue) == .success
    }

    @discardableResult
    func press(_ item: MenuItemInfo) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    /// Walk the whole menu bar once and remember every leaf. Measured at ~750 ms, which is
    /// why it happens at startup and on demand rather than per keystroke.
    func refreshMenuIndex() {
        guard let app = appElement() else { return }
        var found: [[String]: MenuItemInfo] = [:]
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              CFGetTypeID(bar!) == AXUIElementGetTypeID() else { return }
        walk(bar as! AXUIElement, path: [], into: &found)
        index = found
    }

    private func walk(_ element: AXUIElement, path: [String],
                      into found: inout [[String]: MenuItemInfo]) {
        for child in Self.children(of: element) {
            let role = Self.string(child, kAXRoleAttribute) ?? ""
            if role == kAXMenuRole as String {
                walk(child, path: path, into: &found)
                continue
            }
            guard role == kAXMenuItemRole as String || role == kAXMenuBarItemRole as String
            else { continue }
            let title = Self.string(child, kAXTitleAttribute) ?? ""
            guard !title.isEmpty else { continue }
            let here = path + [title]
            if let submenu = Self.children(of: child).first(where: {
                Self.string($0, kAXRoleAttribute) == kAXMenuRole as String
            }) {
                walk(submenu, path: here, into: &found)
            } else {
                found[here] = MenuItemInfo(path: here,
                                           element: child,
                                           shortcut: Self.shortcut(of: child),
                                           isEnabled: Self.bool(child, kAXEnabledAttribute) ?? true)
            }
        }
    }

    /// Read a menu item's shortcut. The decoding itself lives in Core, where it is tested.
    private static func shortcut(of item: AXUIElement) -> KeyEvent? {
        guard let raw = string(item, kAXMenuItemCmdCharAttribute), let char = raw.first
        else { return nil }
        return MenuShortcut.decode(character: char,
                                   mask: int(item, kAXMenuItemCmdModifiersAttribute) ?? 0)
    }

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

    private static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success
        else { return nil }
        return v as? Int
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success
        else { return nil }
        return v as? Bool
    }
}
