import AppKit
import ApplicationServices
import XCommanderCore

/// Everything this app assumes about the *shape* of Xcode's window, in one place.
///
/// The menu bar stopped being a version risk when commands moved to `AXIdentifier`: an
/// action survives a rename, a move and a translation. **Nothing protects the rest of the
/// window.** A source editor is found by the description Xcode gives its text area, a tab
/// bar by the word `tab bar`, a navigator by an identifier that happens to end in
/// `navigator`. None of that is API, none of it is promised, and all of it was discovered by
/// looking.
///
/// So it is gathered here for three reasons. It can be read in one screen when a new Xcode
/// ships; `selfCheck` can ask the running Xcode whether the assumptions still hold instead
/// of waiting for a user to report that panes stopped working; and a reader of the code can
/// see exactly how much of this app rests on undocumented strings — which is more than is
/// comfortable, and worth being honest about.
public enum XcodeAXSchema {

    // MARK: - roles

    public static let textArea = "AXTextArea"
    public static let scrollArea = "AXScrollArea"
    public static let tabGroup = "AXTabGroup"
    public static let radioButton = "AXRadioButton"
    public static let splitter = "AXSplitter"
    public static let outline = "AXOutline"

    // MARK: - the descriptions Xcode sets

    /// The source editor's text area. **The most load-bearing string in the app**: it is
    /// what tells a file being edited apart from every other text area in the window — and
    /// since Xcode 27 moved the coding assistant into the editor area, a conversation
    /// transcript is one of those.
    public static let sourceEditor = "Source Editor"
    /// The editor tab bar. Drawn only when `View > Show Editor Tab Bar` is on, or when some
    /// pane holds more than one tab, so its absence is normal and means nothing.
    public static let tabBar = "tab bar"
    /// The debug area's variables list. Its identifier is a generated `_NS:` number, so the
    /// description is the only stable handle.
    public static let variablesView = "variables view"
    /// The toolbar control holding the editor-creating commands Xcode 27 took out of the
    /// menu bar.
    public static let addEditorButton = "Add Editor"

    /// Each navigator's outline carries its own identifier — `project navigator`,
    /// `issue navigator` — so the shared suffix is matched rather than one spelling.
    public static let navigatorIdentifierSuffix = "navigator"

    // MARK: - how deep to look

    /// Measured at 11 on a one-pane window in Xcode 27, so these are generous. They exist to
    /// bound the walk, not to describe the tree.
    public static let windowWalkDepth = 14
    public static let paneWalkDepth = 12
    public static let tabBarWalkDepth = 6
    /// Toolbar controls sit near the top; an unbounded search for a button is a lot of AX
    /// round trips on a keystroke path.
    public static let toolbarWalkDepth = 4

    // MARK: - is any of this still true?

    /// Which assumption a finding is about, so code can ask about one without matching prose.
    public enum Assumption: String, Sendable {
        case running, focusedWindow
        case sourceEditor, tabBar, navigator, variablesView, addEditorButton, walkDepth

        /// The two whose absence breaks commands outright, rather than meaning "not on screen
        /// right now". Panes, tabs and transforms find the editor by `sourceEditor`; `w v`,
        /// `w s` and `b t` press `addEditorButton`.
        public var isLoadBearing: Bool { self == .sourceEditor || self == .addEditorButton }
    }

    public struct Finding {
        public var kind: Assumption
        public var assumption: String
        public var holds: Bool
        public var detail: String
    }

    /// Ask one Xcode whether its window still looks the way this app expects.
    ///
    /// Deliberately *not* an assertion and not a fault state. Half of these are absent in
    /// perfectly ordinary situations — no navigator is showing, the debug area is closed,
    /// there is only one pane so there is no splitter — so a finding is a hint, not a verdict.
    /// `xcmdr doctor` prints all of them. The app runs this only after a command that needs
    /// the window has already failed, to say *why*; nothing is hidden on the strength of it.
    @MainActor
    public static func selfCheck(of xcode: NSRunningApplication?) -> [Finding] {
        guard let xcode, !xcode.isTerminated else {
            return [Finding(kind: .running, assumption: "Xcode is running", holds: false,
                            detail: "no Xcode process")]
        }
        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              CFGetTypeID(window!) == AXUIElementGetTypeID() else {
            return [Finding(kind: .focusedWindow, assumption: "Xcode has a focused window",
                            holds: false, detail: "none")]
        }

        var roles: [String: Int] = [:]
        var descriptions: Set<String> = []
        var navigatorIdentifiers = 0
        var depth = 0
        func walk(_ element: AXUIElement, _ d: Int) {
            depth = max(depth, d)
            if d > windowWalkDepth { return }
            for child in MenuScanner.children(of: element) {
                let role = MenuScanner.string(child, kAXRoleAttribute) ?? ""
                roles[role, default: 0] += 1
                if let description = MenuScanner.string(child, kAXDescriptionAttribute) {
                    descriptions.insert(description)
                }
                if role == outline,
                   (MenuScanner.string(child, kAXIdentifierAttribute) ?? "")
                    .hasSuffix(navigatorIdentifierSuffix) {
                    navigatorIdentifiers += 1
                }
                walk(child, d + 1)
            }
        }
        walk(window as! AXUIElement, 0)

        return [
            Finding(kind: .sourceEditor, assumption: "the source editor names itself “\(sourceEditor)”",
                    holds: descriptions.contains(sourceEditor),
                    detail: descriptions.contains(sourceEditor)
                        ? "found" : "no text area with that description — panes and transforms depend on it"),
            Finding(kind: .tabBar, assumption: "the editor tab bar names itself “\(tabBar)”",
                    holds: descriptions.contains(tabBar),
                    detail: descriptions.contains(tabBar)
                        ? "found" : "absent — normal unless the tab bar is showing"),
            Finding(kind: .navigator, assumption: "a navigator outline's identifier ends in “\(navigatorIdentifierSuffix)”",
                    holds: navigatorIdentifiers > 0,
                    detail: navigatorIdentifiers > 0
                        ? "\(navigatorIdentifiers) found" : "absent — normal unless a navigator is showing"),
            Finding(kind: .variablesView, assumption: "the debug area names its list “\(variablesView)”",
                    holds: descriptions.contains(variablesView),
                    detail: descriptions.contains(variablesView)
                        ? "found" : "absent — normal unless the debug area is open"),
            Finding(kind: .addEditorButton, assumption: "the “\(addEditorButton)” toolbar control is present",
                    holds: descriptions.contains(addEditorButton),
                    detail: descriptions.contains(addEditorButton)
                        ? "found" : "absent — `w v`, `w s` and `b t` need it"),
            Finding(kind: .walkDepth, assumption: "the window tree fits inside the walk depth of \(windowWalkDepth)",
                    holds: depth <= windowWalkDepth,
                    detail: "deepest element seen at \(depth)"),
        ]
    }
}
