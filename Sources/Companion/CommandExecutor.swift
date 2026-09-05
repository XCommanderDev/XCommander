import AppKit
import CoreGraphics
import CompanionCore
import os

/// Runs a command against Xcode.
///
/// Two tiers, and the choice between them is made per command rather than configured:
///
/// - **Tier 1** — Xcode already has a shortcut for the item, so synthesise it. ~40 µs.
/// - **Tier 2** — it has no shortcut, so press the menu item over Accessibility. ~1 ms.
///
/// A third tier was measured and rejected: writing `NSUserKeyEquivalents` into Xcode's own
/// preferences would let tier 2 become tier 1, but it mutates another application's
/// settings, collides with the user's own App Shortcuts, and needs Xcode restarted before
/// it takes effect. 1 ms is already imperceptible next to the ~350 ms Xcode itself takes
/// to show that anything happened. See `SPIKE-REPORT.md`.
@MainActor
final class CommandExecutor {

    /// Set by the app, because pane work needs Accessibility state the executor does not own.
    var panes: PaneController?

    enum Result: Equatable {
        case posted(KeyEvent)      // tier 1
        case pressed([String])     // tier 2
        case transformed(Int)      // characters written back
        case opensPicker(PickerKind)
        case handledInternally(String)
        case unavailable(String)   // and why, for the log and the menu bar
        case movedPane
    }

    private func performPane(_ action: PaneAction) -> Result {
        guard let panes else { return .unavailable("pane control is not available") }
        let ok: Bool
        switch action {
        case .focus(let direction): ok = panes.focus(direction)
        case .balance: ok = panes.resize(.balance)
        case .zoom: ok = panes.resize(.zoom)
        case .grow: ok = panes.resize(.grow)
        case .shrink: ok = panes.resize(.shrink)
        }
        return ok ? .movedPane : .unavailable("no pane in that direction")
    }

    private let context: XcodeContext
    private let source = CGEventSource(stateID: .hidSystemState)
    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "executor")

    /// Companion commands (quit, reload) are handed back out rather than performed here,
    /// so the executor has no opinion about the app's lifecycle.
    var onCompanionCommand: ((String) -> Void)?

    init(context: XcodeContext) {
        self.context = context
    }

    @discardableResult
    func run(_ command: Command) -> Result {
        switch command.action {
        case .companion(let id):
            onCompanionCommand?(id)
            return .handledInternally(id)

        case .picker(let kind):
            // The app owns pickers, because only it can supply their rows.
            return .opensPicker(kind)

        case .transform(let transform):
            return apply(transform)

        case .pane(let action):
            return performPane(action)

        case .shortcut(let key):
            return post(key) ? .posted(key) : .unavailable("could not post \(key.display)")

        case .menuPath(let path):
            guard let item = context.menuItem(at: path) else {
                // Xcode's menu tree is context-dependent: the Editor menu has 6 items with
                // no source editor focused and 150 with a .swift file open. A missing path
                // is a normal state, not a bug.
                return .unavailable("\(path.joined(separator: " > ")) is not in the menu right now")
            }
            guard item.isEnabled else {
                return .unavailable("\(command.title) is disabled right now")
            }
            if let key = item.shortcut, post(key) {
                return .posted(key)
            }
            return context.press(item)
                ? .pressed(path)
                : .unavailable("could not press \(path.joined(separator: " > "))")
        }
    }

    /// Rewrite the editor's selection.
    ///
    /// With nothing selected, the current line is selected first — which is what every
    /// editor does, and what makes `align` or `join` useful without a mouse. Xcode's own
    /// undo reverts the write, so `⌘Z` takes it back.
    private func apply(_ transform: TextTransform) -> Result {
        guard context.selectCurrentLineIfEmpty() else {
            return .unavailable("no source editor is focused")
        }
        guard let selection = context.selectedText(), !selection.isEmpty else {
            return .unavailable("nothing to transform")
        }
        let result = transform.apply(to: selection)
        guard result != selection else { return .transformed(0) }
        guard context.replaceSelection(with: result) else {
            return .unavailable("could not write to the editor")
        }
        return .transformed(result.count)
    }

    /// Post a synthetic keystroke.
    ///
    /// The character is resolved against the live keyboard layout, and Shift is added when
    /// the character needs it: `⌘%` on AZERTY is really Command-Shift on the `ù` key, and
    /// posting it without Shift silently does nothing.
    private func post(_ key: KeyEvent) -> Bool {
        let keyCode: CGKeyCode
        var modifiers = key.modifiers

        switch key.key {
        case .special(let special):
            keyCode = KeyboardLayout.keyCode(for: special)
        case .character(let character):
            guard let resolved = KeyboardLayout.resolve(character) else {
                log.error("no key on this layout produces '\(String(character))'")
                return false
            }
            keyCode = resolved.keyCode
            if resolved.needsShift { modifiers.insert(.shift) }
        }

        let flags = EventBridge.flags(from: modifiers)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
