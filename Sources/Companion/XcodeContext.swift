import AppKit
import ApplicationServices
import AutographeCore
import XcodeMenus
import os

/// What we need to know about Xcode. Behind a protocol because it is the least testable
/// part of the system and the most likely to break across Xcode versions.
@MainActor
protocol XcodeContext {
    var isRunning: Bool { get }
    var isFrontmost: Bool { get }
    /// Which Xcode is running, or nil when none is. Read once per process rather than per
    /// query: it comes off disk, and it cannot change without the pid changing.
    var release: XcodeRelease? { get }
    /// Xcode's focused window in AX coordinates (top-left origin), or nil if it will not say.
    func focusedWindowFrame() -> CGRect?
    /// Look a menu item up by the action behind it. Nil when this Xcode does not offer it.
    func menuItem(for ref: MenuRef) -> MenuItemInfo?
    /// Press a menu item over Accessibility. ~1 ms once the element is resolved.
    @discardableResult func press(_ item: MenuItemInfo) -> Bool
    /// Press an item inside a toolbar popup. True means the control was found and the menu
    /// was asked to open; the press itself finishes asynchronously.
    @discardableResult func pressPopupItem(_ ref: PopupMenuRef) -> Bool
    /// Re-read the menu bar. Expensive (~750 ms), so it is explicit rather than automatic.
    func refreshMenuIndex()
    /// The most recent full scan, for the store to fold into what it already knows.
    var lastScan: MenuSnapshot? { get }
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
    /// Every open editor tab, across every pane, in on-screen order.
    ///
    /// **Empty more often than you would guess.** Xcode draws editor tab bars only when `View > Show Editor Tab Bar` is on, or
    /// when some pane holds more than one tab — and then it draws one in *every* pane. With
    /// Xcode's default setting and one file per pane there are no tab bars at all, so this
    /// returns empty far more often than "you have one file open".
    /// The caller falls back accordingly.
    func openEditors() -> [EditorTab]
    /// Switch to a tab by the coordinates `openEditors` gave out. False when the tree has
    /// moved on and those coordinates no longer name anything.
    @discardableResult func selectTab(pane: Int, index: Int) -> Bool
}

struct MenuItemInfo {
    /// `AXIdentifier` — the Objective-C action behind the item. Empty for the handful that
    /// have none.
    var identifier: String
    /// Where the item sits *right now*, for display and for the palette's search text.
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

    private static let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "menus")

    private var app: AXUIElement?
    private var pid: pid_t?
    /// The live menu, indexed the same way a checked-in snapshot is, so that resolution is
    /// one implementation — `MenuCatalogue`, in Core, under test — rather than two that
    /// drift. The elements are kept beside it because Core has no AppKit and no business
    /// holding an `AXUIElement`.
    private var catalogue: MenuCatalogue?
    private var elements: [[String]: (element: AXUIElement, isEnabled: Bool)] = [:]
    private var cachedRelease: XcodeRelease?
    /// The most recent full scan, for whoever wants to record it. Not the same thing as the
    /// catalogue, which is only the lookup table built from it.
    private(set) var lastScan: MenuSnapshot?

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

    var release: XcodeRelease? {
        _ = appElement()   // binds to the current process, filling the cache on a change
        return cachedRelease
    }

    /// Rebind to Xcode's current process, dropping any cached menu elements if the pid
    /// changed. Menu `AXUIElement`s belong to a process and are meaningless after a relaunch.
    private func appElement() -> AXUIElement? {
        guard let running = runningXcode else {
            app = nil; pid = nil; catalogue = nil; elements = [:]; cachedRelease = nil
            return nil
        }
        if running.processIdentifier != pid {
            pid = running.processIdentifier
            app = AXUIElementCreateApplication(running.processIdentifier)
            catalogue = nil; elements = [:]
            cachedRelease = Self.runningRelease()
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

    /// Look a menu item up by the action behind it.
    ///
    /// There is no fallback, and that is the point. The old version matched a path, then a
    /// `Show`/`Hide` sibling, then a prefix on the last component — three guesses, each of
    /// which could land on a different item than the one meant. `File > Close “` matched
    /// whatever document happened to be open. An identifier either names the command or it
    /// does not, and "it does not" is a fact worth reporting rather than papering over.
    func menuItem(for ref: MenuRef) -> MenuItemInfo? {
        if catalogue == nil { refreshMenuIndex() }
        guard let catalogue, case .bound(let entry, _) = catalogue.resolve(ref),
              let found = elements[entry.path] else { return nil }
        return MenuItemInfo(identifier: entry.identifier,
                            path: entry.path,
                            element: found.element,
                            shortcut: entry.shortcut,
                            isEnabled: found.isEnabled)
    }

    func allMenuItems() -> [MenuItemInfo] {
        if catalogue == nil { refreshMenuIndex() }
        return (catalogue?.entries ?? [])
            .compactMap(info(for:))
            .sorted { $0.path.joined() < $1.path.joined() }
    }

    func menuItems(under prefix: [String]) -> [MenuItemInfo] {
        if catalogue == nil { refreshMenuIndex() }
        // Keyed by path rather than by identifier because this asks about the menu's
        // *shape*: `Product > Destination` is 102 items sharing one action, and the whole
        // list is what the picker wants.
        return (catalogue?.items(under: prefix) ?? []).compactMap(info(for:))
    }

    private func info(for entry: MenuEntry) -> MenuItemInfo? {
        guard let found = elements[entry.path] else { return nil }
        return MenuItemInfo(identifier: entry.identifier, path: entry.path,
                            element: found.element, shortcut: entry.shortcut,
                            isEnabled: found.isEnabled)
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
        guard Self.string(element, kAXRoleAttribute) == XcodeAXSchema.textArea else { return nil }
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

    /// Press an item in one of Xcode's toolbar popups.
    ///
    /// Unavoidably a small dance: an `AXMenuButton` has no children until its menu is open,
    /// so the menu must be asked to open, waited for, and only then searched. That waiting
    /// happens **off the main actor** — a fiftieth of a second of a blocked main thread is a
    /// dropped keystroke, which is the one thing this app must never do.
    ///
    /// Returns as soon as the control is found, following the same rule as `swap` and
    /// `send`: true means the preconditions held, and a later failure is a log line.
    @discardableResult
    func pressPopupItem(_ ref: PopupMenuRef) -> Bool {
        guard popupButton(named: ref.button) != nil,
              let pid = runningXcode?.processIdentifier else { return false }
        let button = ref.button, identifier = ref.item.identifier
        Task.detached {
            if !PopupReader.press(button: button, identifier: identifier, pid: pid) {
                await Self.log.notice("\(identifier, privacy: .public) could not be pressed in the \(button, privacy: .public) popup")
            }
        }
        return true
    }

    /// Find a toolbar control by the description Xcode gives it. Shallow on purpose: these
    /// live near the top of the window, and an unbounded walk of the whole tree to find a
    /// button is a lot of AX round trips on a keystroke path.
    private func popupButton(named description: String) -> AXUIElement? {
        guard let app = appElement() else { return nil }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win!) == AXUIElementGetTypeID() else { return nil }
        var found: AXUIElement?
        func descend(_ element: AXUIElement, _ depth: Int) {
            if found != nil || depth > XcodeAXSchema.toolbarWalkDepth { return }
            for child in Self.children(of: element) {
                if Self.string(child, kAXDescriptionAttribute) == description { found = child; return }
                descend(child, depth + 1)
            }
        }
        descend(win as! AXUIElement, 0)
        return found
    }

    /// Re-read the whole menu bar. Measured at ~750 ms, which is why it happens at startup
    /// and on demand rather than per keystroke.
    ///
    /// The walk itself lives in `XcodeMenus`, shared with `xcmdr`, so that an audit is an
    /// audit of the menu the app actually sees. Every scan is also folded into the store, so
    /// that across a few sessions the app learns what this Xcode *can* offer rather than
    /// what it happened to be showing once.
    func refreshMenuIndex() {
        guard let scan = try? MenuScanner.scan(context: Self.describeContext(),
                                               timeout: Self.messagingTimeout) else { return }
        elements = scan.elements
        catalogue = MenuCatalogue(scan.snapshot)
        lastScan = scan.snapshot
    }

    /// What was on screen when the menus were read, so a stored snapshot says which context
    /// it is a record of. Cheap, and it is the difference between "Apple deleted this" and
    /// "no editor was focused".
    private static func describeContext() -> String {
        var parts: [String] = []
        parts.append(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dt.Xcode"
                     ? "Xcode frontmost" : "Xcode in the background")
        return parts.joined(separator: ", ")
    }

    /// Which Xcode is running, for the catalogue and for the support floor.
    static func runningRelease() -> XcodeRelease {
        MenuScanner.runningRelease() ?? XcodeRelease(version: "unknown", build: "unknown", major: 0)
    }

    // MARK: - open editors

    /// One editor pane, with the tab bar that belongs to it.
    private struct PaneScan {
        var frame: CGRect
        var isFocused: Bool
        var tabs: [(element: AXUIElement, title: String, isActive: Bool)]
    }

    /// Panes and tab bars in a single traversal, then paired up by geometry.
    ///
    /// They are separate subtrees — a tab bar is not a child of the pane it labels — so the
    /// only honest way to associate them is where they sit: a pane's tab bar is the one
    /// horizontally inside it and immediately above it. Measured on a four-pane layout the
    /// bar is inset 58pt and sits 33pt clear of the editor, so the tolerances below are
    /// generous in y and use containment in x.
    private func scanPanes() -> [PaneScan] {
        guard let app = appElement() else { return [] }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win!) == AXUIElementGetTypeID() else { return [] }

        var panes: [(frame: CGRect, focused: Bool)] = []
        var bars: [(frame: CGRect, element: AXUIElement)] = []

        func walk(_ element: AXUIElement, _ depth: Int) {
            if depth > XcodeAXSchema.windowWalkDepth { return }
            for child in Self.children(of: element) {
                switch Self.string(child, kAXRoleAttribute) ?? "" {
                case XcodeAXSchema.scrollArea:
                    if let editor = Self.children(of: child).first(where: {
                        Self.string($0, kAXRoleAttribute) == XcodeAXSchema.textArea
                            && Self.string($0, kAXDescriptionAttribute) == XcodeAXSchema.sourceEditor
                    }), let frame = Self.frame(of: child) {
                        panes.append((frame, Self.bool(editor, kAXFocusedAttribute) ?? false))
                    }
                case XcodeAXSchema.tabGroup:
                    if Self.string(child, kAXDescriptionAttribute) == XcodeAXSchema.tabBar,
                       let frame = Self.frame(of: child) {
                        bars.append((frame, child))
                    }
                default:
                    break
                }
                walk(child, depth + 1)
            }
        }
        walk(win as! AXUIElement, 0)

        // Left to right, then top to bottom — the same ordering `PaneLayout` uses, so a
        // pane index means the same thing to the picker as it does to `w h/j/k/l`.
        panes.sort { $0.frame.minX == $1.frame.minX ? $0.frame.minY < $1.frame.minY
                                                    : $0.frame.minX < $1.frame.minX }

        return panes.map { pane in
            let bar = bars
                .filter { $0.frame.midX >= pane.frame.minX && $0.frame.midX <= pane.frame.maxX
                          && $0.frame.maxY <= pane.frame.minY + 8
                          && pane.frame.minY - $0.frame.maxY < 80 }
                .max { $0.frame.maxY < $1.frame.maxY }
            return PaneScan(frame: pane.frame, isFocused: pane.focused,
                            tabs: bar.map(Self.tabs(in:)) ?? [])
        }
    }

    /// The tabs in one tab bar. The radio buttons sit below an intermediate group rather
    /// than directly under the bar, so this descends instead of reading `AXChildren` once.
    private static func tabs(in bar: (frame: CGRect, element: AXUIElement))
        -> [(element: AXUIElement, title: String, isActive: Bool)] {
        var found: [(AXUIElement, String, Bool)] = []
        func collect(_ element: AXUIElement, _ depth: Int) {
            if depth > XcodeAXSchema.tabBarWalkDepth { return }
            for child in children(of: element) {
                if string(child, kAXRoleAttribute) == XcodeAXSchema.radioButton,
                   let title = string(child, kAXTitleAttribute), !title.isEmpty {
                    found.append((child, title, (int(child, kAXValueAttribute) ?? 0) == 1))
                }
                collect(child, depth + 1)
            }
        }
        collect(bar.element, 0)
        return found.map { (element: $0.0, title: $0.1, isActive: $0.2) }
    }

    func openEditors() -> [EditorTab] {
        scanPanes().enumerated().flatMap { paneIndex, pane in
            pane.tabs.enumerated().map { tabIndex, tab in
                EditorTab(pane: paneIndex, index: tabIndex, title: tab.title,
                          isActive: tab.isActive, isInFocusedPane: pane.isFocused)
            }
        }
    }

    @discardableResult
    func selectTab(pane: Int, index: Int) -> Bool {
        let scan = scanPanes()
        guard scan.indices.contains(pane), scan[pane].tabs.indices.contains(index) else {
            return false
        }
        return AXUIElementPerformAction(scan[pane].tabs[index].element,
                                        kAXPressAction as CFString) == .success
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
