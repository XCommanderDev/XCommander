import AppKit
import ApplicationServices
import AutographeCore
import Carbon

/// Reading Xcode's menu bar over Accessibility, in one place.
///
/// It lives in its own target because two programs need it and they are not the same
/// program: the app walks the menus to run commands, and `xcmdr` walks them to report on
/// what Apple has done. Both must produce *identical* snapshots or the audit would be
/// auditing something other than what ships.
public enum MenuScanner {

    public static let bundleIdentifier = "com.apple.dt.Xcode"

    /// Every running copy of Xcode. Usually one; a release and a beta side by side is normal.
    /// One that is on its way out is not a candidate — the quit notification can arrive while
    /// the process is still listed.
    public static var runningXcodes: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
    }

    /// The Xcode to talk to, by the rule in `XcodeTarget`, or nil when none is running.
    ///
    /// - Parameter lastActive: the pid that was in front most recently. The app tracks it;
    ///   `xcmdr` has no history and passes nil.
    public static func target(lastActive: pid_t? = nil) -> NSRunningApplication? {
        let running = runningXcodes
        let chosen = XcodeTarget.choose(running.map(instance(of:)), lastActive: lastActive)
        return running.first { $0.processIdentifier == chosen?.pid }
    }

    public static func instance(of app: NSRunningApplication) -> XcodeInstance {
        XcodeInstance(pid: app.processIdentifier,
                      bundlePath: app.bundleURL?.path ?? "",
                      isActive: app.isActive,
                      launchDate: app.launchDate)
    }

    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Which Xcode a process is, read from its bundle rather than from `xcodebuild -version`:
    /// the process whose menus we are about to read need not be the selected toolchain, and
    /// with two Xcodes running it is the only way to know which one answered.
    public static func release(of xcode: NSRunningApplication) -> XcodeRelease? {
        guard let url = xcode.bundleURL,
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        let version = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        return XcodeRelease(version: version,
                            build: (info["DTXcodeBuild"] as? String) ?? "unknown",
                            major: Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0)
    }

    /// The keyboard the shortcuts were read through. Xcode reports the *character* a
    /// shortcut produces, so this is the difference between "Apple rebound a command" and
    /// "these two captures were taken on different keyboards".
    public static func currentInputSource() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    public enum ScanFailure: Error, CustomStringConvertible {
        case noAccessibility, notRunning, noMenuBar

        public var description: String {
            switch self {
            case .noAccessibility: "this process has no Accessibility permission"
            case .notRunning: "Xcode is not running"
            case .noMenuBar: "Xcode has no menu bar right now"
            }
        }
    }

    /// One scan of the whole menu bar.
    ///
    /// `elements` is kept beside the snapshot rather than inside it because Core has no
    /// AppKit and no business holding an `AXUIElement`, and because a snapshot outlives the
    /// process that made it while an element does not.
    public struct Scan {
        public var snapshot: MenuSnapshot
        public var elements: [[String]: (element: AXUIElement, isEnabled: Bool)]
    }

    /// Walk every menu of one Xcode and record every leaf. Measured at ~750 ms.
    ///
    /// The caller names the process. Scanning "whichever Xcode comes first" would record the
    /// menus of one copy under the build number of another.
    ///
    /// - Parameter timeout: AX messaging timeout. The app wants a quarter second because a
    ///   blocked Xcode main thread is a normal state; `xcmdr` wants ten, because it runs
    ///   once by hand and a truncated snapshot is worse than a slow one.
    public static func scan(of xcode: NSRunningApplication?, context: String,
                            timeout: Float = 0.25) throws -> Scan {
        guard hasAccessibility else { throw ScanFailure.noAccessibility }
        guard let running = xcode, !running.isTerminated else { throw ScanFailure.notRunning }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, timeout)

        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              CFGetTypeID(bar!) == AXUIElementGetTypeID() else { throw ScanFailure.noMenuBar }

        var entries: [MenuEntry] = []
        var elements: [[String]: (element: AXUIElement, isEnabled: Bool)] = [:]
        walk(bar as! AXUIElement, path: [], entries: &entries, elements: &elements)
        entries.sort { $0.path.lexicographicallyPrecedes($1.path) }

        let editorFocused = isSourceEditorFocused(app)
        let snapshot = MenuSnapshot(
            release: release(of: running) ?? XcodeRelease(version: "unknown", build: "unknown", major: 0),
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            context: editorFocused ? context + ", source editor focused" : context,
            inputSource: currentInputSource(),
            entries: entries,
            editorScans: editorFocused ? 1 : 0)
        return Scan(snapshot: snapshot, elements: elements)
    }

    /// Whether the keyboard focus was in a source editor while the menus were read — the
    /// context in which Xcode's menus are fullest, and the one `MenuSnapshot.isSettled`
    /// waits for.
    ///
    /// If Apple renames the editor's description this is never true, nothing settles, and
    /// the app shows every key and reports nothing. That is the safe way to fail, and
    /// `xcmdr doctor` names the assumption that broke.
    private static func isSourceEditorFocused(_ app: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        return string(element, kAXRoleAttribute) == XcodeAXSchema.textArea
            && string(element, kAXDescriptionAttribute) == XcodeAXSchema.sourceEditor
    }

    private static func walk(_ element: AXUIElement, path: [String],
                             entries: inout [MenuEntry],
                             elements: inout [[String]: (element: AXUIElement, isEnabled: Bool)]) {
        for child in children(of: element) {
            let role = string(child, kAXRoleAttribute) ?? ""
            if role == kAXMenuRole as String {
                walk(child, path: path, entries: &entries, elements: &elements)
                continue
            }
            guard role == kAXMenuItemRole as String || role == kAXMenuBarItemRole as String
            else { continue }
            let title = string(child, kAXTitleAttribute) ?? ""
            guard !title.isEmpty else { continue }
            let here = path + [title]
            if let submenu = children(of: child).first(where: {
                string($0, kAXRoleAttribute) == kAXMenuRole as String
            }) {
                walk(submenu, path: here, entries: &entries, elements: &elements)
                continue
            }
            // The Apple menu is the system's, not Xcode's. Leaving it out also keeps a diff
            // between two Xcodes free of the user's own Recent Items churn.
            guard here.first != "Apple" else { continue }
            let identifier = string(child, kAXIdentifierAttribute) ?? ""
            entries.append(MenuEntry(identifier: identifier,
                                     title: title,
                                     path: here,
                                     cmdChar: string(child, kAXMenuItemCmdCharAttribute),
                                     cmdModifiers: int(child, kAXMenuItemCmdModifiersAttribute) ?? 0,
                                     cmdVirtualKey: int(child, kAXMenuItemCmdVirtualKeyAttribute)))
            // Two items can share a path — `Window > Move & Resize > Quarters` is both a
            // section header and a command — and only one of them does anything.
            if elements[here] == nil || !identifier.isEmpty {
                elements[here] = (child, bool(child, kAXEnabledAttribute) ?? true)
            }
        }
    }

    // MARK: - thin AX accessors

    public static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    public static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Int
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }
}
