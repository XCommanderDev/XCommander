import AppKit
import ApplicationServices
import CompanionCore
import os

/// Editor panes, over Accessibility.
///
/// Xcode can only cycle between panes and offers an interactive chooser. Everything a vim
/// or Emacs user reaches for — go *left*, balance, zoom, widen — is missing, and all of it
/// is reachable: panes enumerate as scroll areas with frames, `AXFocused` is settable on
/// the one you want, and an `AXSplitter`'s `AXValue` moves the divider one point per unit.
@MainActor
final class PaneController {

    private let context: XcodeContext
    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "panes")
    /// Where the divider was before a zoom, so the same key puts it back.
    private var zoomedFrom: Int?

    init(context: XcodeContext) {
        self.context = context
    }

    private struct PaneRef {
        let editor: AXUIElement
        let frame: PaneRect
        let isFocused: Bool
    }

    // MARK: - reading the layout

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

    private struct SplitterRef {
        let element: AXUIElement
        let frame: PaneRect
        let value: Int
    }

    /// Panes and splitters in a **single** traversal.
    ///
    /// Walking twice was a real bug, not just waste: a second walk a few milliseconds later
    /// came back without the splitters, and every resize reported "no pane in that
    /// direction" while the geometry was plainly right. One walk is also one round of AX
    /// calls instead of three on a keystroke path.
    ///
    /// The scroll area is the pane's *visible* bounds; the text area inside it is as tall
    /// as the document, which is useless for deciding what sits above what.
    private func layout() -> (panes: [PaneRef], splitters: [SplitterRef]) {
        guard let window = window() else { return ([], []) }
        var panes: [PaneRef] = []
        var splitters: [SplitterRef] = []
        walk(window, depth: 0) { element, role in
            switch role {
            case "AXScrollArea":
                guard let editor = Self.children(element).first(where: { Self.role(of: $0) == "AXTextArea" }),
                      let frame = Self.frame(of: element) else { return }
                panes.append(PaneRef(editor: editor, frame: frame,
                                     isFocused: Self.bool(editor, kAXFocusedAttribute) ?? false))
            case "AXSplitter":
                guard let frame = Self.frame(of: element),
                      let value = Self.int(element, kAXValueAttribute) else { return }
                splitters.append(SplitterRef(element: element, frame: frame, value: value))
            default:
                return
            }
        }
        // Left to right, then top to bottom, so indices are stable between calls.
        panes.sort { $0.frame.minX == $1.frame.minX ? $0.frame.minY < $1.frame.minY
                                                    : $0.frame.minX < $1.frame.minX }
        return (panes, splitters)
    }

    private func walk(_ element: AXUIElement, depth: Int, visit: (AXUIElement, String) -> Void) {
        if depth > 12 { return }
        for child in Self.children(element) {
            visit(child, Self.role(of: child))
            walk(child, depth: depth + 1, visit: visit)
        }
    }

    // MARK: - commands

    /// Focus the pane in a direction. The geometry is `PaneLayout`, in Core, under test.
    @discardableResult
    func focus(_ direction: PaneDirection) -> Bool {
        let refs = layout().panes
        guard refs.count > 1 else { return false }
        let model = refs.enumerated().map {
            Pane(index: $0.offset, frame: $0.element.frame, isFocused: $0.element.isFocused)
        }
        guard let current = model.first(where: \.isFocused) ?? model.first,
              let target = PaneLayout.target(from: current, direction: direction, among: model)
        else { return false }
        let ok = AXUIElementSetAttributeValue(refs[target.index].editor,
                                              kAXFocusedAttribute as CFString,
                                              kCFBooleanTrue) == .success
        if !ok { log.notice("could not focus the pane to the \(String(describing: direction), privacy: .public)") }
        return ok
    }

    // MARK: - moving buffers between panes

    /// Exchange the focused pane's file with the next pane's. Vim's `⌃w x`.
    ///
    /// Xcode has no such command, and the split tree's shape is not writable from outside,
    /// so this is synthesised from the two things that *are* possible: reading a pane's
    /// document (the window's `AXDocument` follows the focused pane) and re-opening a file
    /// into whichever pane has focus.
    ///
    /// It runs as a `Task` rather than inline because each step has to wait for Xcode to
    /// catch up, and the caller is the event-tap keystroke path — which must never block.
    /// The return value therefore says "the preconditions hold", not "it finished".
    @discardableResult
    func swap() -> Bool {
        let panes = layout().panes
        guard panes.count > 1, let from = panes.firstIndex(where: \.isFocused) else { return false }
        let to = (from + 1) % panes.count
        Task { await exchange(from, to) }
        return true
    }

    /// Open the focused pane's file in the pane in a direction, and go there.
    ///
    /// Named `send` and not `move` on purpose: vim's `⌃w H/J/K/L` relocates the *window*,
    /// which cannot be done here, and promising it in the which-key panel would be a lie.
    /// This sends the buffer, which is the useful half.
    @discardableResult
    func send(_ direction: PaneDirection) -> Bool {
        let refs = layout().panes
        guard refs.count > 1 else { return false }
        let model = refs.enumerated().map {
            Pane(index: $0.offset, frame: $0.element.frame, isFocused: $0.element.isFocused)
        }
        guard let current = model.first(where: \.isFocused) ?? model.first,
              let target = PaneLayout.target(from: current, direction: direction, among: model),
              let document = editableDocument() else { return false }
        Task { await open(document, inPaneAt: target.index) }
        return true
    }

    /// How long to let Xcode settle after a focus change or an open.
    ///
    /// Both are asynchronous on Xcode's side: `AXFocused` returns before the window's
    /// `AXDocument` has caught up, and `xed` returns before the file is on screen. These are
    /// the values that were reliable when driving a four-pane layout; they are deliberately
    /// unhurried, because a swap is a one-shot deliberate command and a wrong answer here
    /// silently swaps the wrong file.
    private static let focusSettle = Duration.milliseconds(200)
    private static let openSettle = Duration.milliseconds(500)

    private func exchange(_ from: Int, _ to: Int) async {
        guard let a = await document(ofPaneAt: from),
              let b = await document(ofPaneAt: to) else {
            log.notice("swap: could not read both panes' documents")
            return
        }
        guard a != b else {
            log.notice("swap: both panes show the same file")
            return
        }
        await open(b, inPaneAt: from)
        await open(a, inPaneAt: to)
        // Leave the user where they started, now looking at the other file.
        _ = focusPane(at: from)
    }

    /// Focus a pane and ask the window what it is showing. The window's `AXDocument`
    /// follows the focused pane, which is the only route to a pane's *path*: a tab reports
    /// a file name and nothing more.
    private func document(ofPaneAt index: Int) async -> URL? {
        guard focusPane(at: index) else { return nil }
        try? await Task.sleep(for: Self.focusSettle)
        return editableDocument()
    }

    private func open(_ url: URL, inPaneAt index: Int) async {
        guard focusPane(at: index) else { return }
        try? await Task.sleep(for: Self.focusSettle)
        XcodeOpen.file(at: url.path)
        try? await Task.sleep(for: Self.openSettle)
    }

    /// The pane list is re-read on every step rather than cached: opening a file rebuilds
    /// parts of the tree, and a stale `AXUIElement` fails silently instead of loudly.
    private func focusPane(at index: Int) -> Bool {
        let panes = layout().panes
        guard panes.indices.contains(index) else { return false }
        return AXUIElementSetAttributeValue(panes[index].editor, kAXFocusedAttribute as CFString,
                                            kCFBooleanTrue) == .success
    }

    /// The focused pane's file, excluding the case where `AXDocument` is a *directory* —
    /// which is what a workspace window reports when a `Package.swift` is opened as a
    /// package. A directory is not a buffer, and `xed` on one reopens the whole project.
    private func editableDocument() -> URL? {
        guard let url = context.documentURL(), url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return url
    }

    enum SizeChange {
        case balance, zoom, grow, shrink
    }

    /// Resize around the divider between the focused pane and its neighbour.
    @discardableResult
    func resize(_ change: SizeChange) -> Bool {
        let (refs, all) = layout()
        guard refs.count > 1, let focusedIndex = refs.firstIndex(where: \.isFocused) else { return false }

        // The divider that actually separates the focused pane from a neighbour, rather
        // than the navigator's or the debug area's.
        guard let pair = neighbouring(refs, focusedIndex, all) else { return false }
        let (splitter, before, after, focusIsBefore) = pair

        let value: Int
        switch change {
        case .balance:
            zoomedFrom = nil
            value = PaneResize.balanced(currentValue: splitter.value, before: before, after: after)
        case .zoom:
            // The same key zooms and unzooms.
            if let previous = zoomedFrom {
                zoomedFrom = nil
                value = previous
            } else {
                zoomedFrom = splitter.value
                value = PaneResize.maximized(currentValue: splitter.value, before: before,
                                             after: after, focusIsBefore: focusIsBefore)
            }
        case .grow:
            value = PaneResize.resized(currentValue: splitter.value, before: before, after: after,
                                       focusIsBefore: focusIsBefore, by: 80)
        case .shrink:
            value = PaneResize.resized(currentValue: splitter.value, before: before, after: after,
                                       focusIsBefore: focusIsBefore, by: -80)
        }
        // A split view refuses a position it cannot honour rather than clamping it, and
        // the real limit depends on what the panes contain. Ask for the ideal position,
        // then settle for the best one it will accept.
        for candidate in PaneResize.ladder(from: splitter.value, to: value) {
            let err = AXUIElementSetAttributeValue(splitter.element, kAXValueAttribute as CFString,
                                                   candidate as CFTypeRef)
            if err == .success {
                if candidate != value {
                    log.debug("splitter accepted \(candidate) rather than \(value)")
                }
                return true
            }
        }
        log.notice("the divider would not move to \(value, privacy: .public)")
        return false
    }

    /// Find the divider between the focused pane and the pane next to it, and say which
    /// side the focus is on. Horizontal splits first, then vertical.
    private func neighbouring(_ refs: [PaneRef], _ focusedIndex: Int, _ all: [SplitterRef])
        -> (splitter: SplitterRef, before: Double, after: Double, focusIsBefore: Bool)? {
        let focused = refs[focusedIndex].frame

        for (neighbourIndex, neighbour) in refs.enumerated() where neighbourIndex != focusedIndex {
            let other = neighbour.frame
            // Side by side: a divider sits in the gap between them, spanning vertically.
            if abs(other.minY - focused.minY) < 4 {
                let leftIsFocus = focused.minX < other.minX
                let gapStart = leftIsFocus ? focused.maxX : other.maxX
                let gapEnd = leftIsFocus ? other.minX : focused.minX
                if let splitter = all.first(where: {
                    $0.frame.minX >= gapStart - 8 && $0.frame.maxX <= gapEnd + 8
                        && $0.frame.height > $0.frame.width
                }) {
                    return (splitter,
                            leftIsFocus ? focused.width : other.width,
                            leftIsFocus ? other.width : focused.width,
                            leftIsFocus)
                }
            }
            // Stacked: the divider spans horizontally.
            if abs(other.minX - focused.minX) < 4 {
                let topIsFocus = focused.minY < other.minY
                let gapStart = topIsFocus ? focused.maxY : other.maxY
                let gapEnd = topIsFocus ? other.minY : focused.minY
                if let splitter = all.first(where: {
                    $0.frame.minY >= gapStart - 8 && $0.frame.maxY <= gapEnd + 8
                        && $0.frame.width > $0.frame.height
                }) {
                    return (splitter,
                            topIsFocus ? focused.height : other.height,
                            topIsFocus ? other.height : focused.height,
                            topIsFocus)
                }
            }
        }
        return nil
    }

    // MARK: - AX helpers

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &v) == .success
        else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    private static func role(of element: AXUIElement) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &v) == .success
        else { return "" }
        return (v as? String) ?? ""
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success
        else { return nil }
        return v as? Bool
    }

    private static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success
        else { return nil }
        return v as? Int
    }

    private static func frame(of element: AXUIElement) -> PaneRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return PaneRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }
}
