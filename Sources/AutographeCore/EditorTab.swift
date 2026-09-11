import Foundation

/// One open editor tab, as read off Xcode's own tab bars.
///
/// **This is the buffer list, and it is Xcode's rather than ours.** It replaced a guessed
/// MRU built by watching which document had focus, which was the honest thing to do while we
/// believed Xcode exposed no tabs at all. It does: every editor *pane* carries an
/// `AXTabGroup`, its tabs are `AXRadioButton`s titled by file name, `AXValue == 1` marks the
/// active one, and pressing one switches to it. So the list can be the truth — every file
/// actually open, in every pane, in the order they sit on screen — instead of a recollection.
///
/// **What it cannot see.** Xcode draws editor tab bars only when `View > Show Editor Tab Bar`
/// is on, or when some pane holds more than one tab — and then it draws one in every pane. On a
/// default Xcode with one file per pane there are no tab bars, and this list is empty. That is
/// why `DocumentHistory` survives behind it rather than being deleted.
///
/// A tab is addressed by **coordinates, not by path**. Its title is only a file name, so two
/// `main.swift` in different targets are indistinguishable, and there is no attribute
/// carrying the full URL. The app re-resolves `(pane, index)` against the live tree when a
/// row is chosen.
public struct EditorTab: Hashable, Sendable {
    /// Which editor pane holds this tab, in on-screen order: left to right, then top to
    /// bottom, the same ordering `PaneLayout` uses.
    public let pane: Int
    /// Position within that pane's tab bar.
    public let index: Int
    /// The file name Xcode shows on the tab. Not a path.
    public let title: String
    /// The tab currently showing in its pane.
    public let isActive: Bool
    /// Whether that pane is the one with keyboard focus.
    public let isInFocusedPane: Bool

    public init(pane: Int, index: Int, title: String,
                isActive: Bool, isInFocusedPane: Bool) {
        self.pane = pane
        self.index = index
        self.title = title
        self.isActive = isActive
        self.isInFocusedPane = isInFocusedPane
    }

    /// The one file you are looking at: the active tab of the focused pane.
    public var isCurrent: Bool { isActive && isInFocusedPane }
}

public enum EditorTabList {

    /// Rows for the buffer picker.
    ///
    /// Ordered as they sit on screen, so the list matches what the eye already knows. The
    /// current file is **left out**: switching to where you already are is not a switch, and
    /// it is the row you would otherwise land on by default.
    ///
    /// The pane is named only when there is more than one, because "pane 1" against a single
    /// pane is noise that pushes the file name off the line.
    ///
    /// **Xcode lets the same file be open in several tabs of one pane** — its tabs are views
    /// with their own scroll position and history, not buffers — so a title can genuinely
    /// repeat inside a pane. Those rows are otherwise identical on screen: same name, and the
    /// pane number cannot separate them because it is the same pane. They get a tab position
    /// so the reader can tell them apart. Repeats *across* panes need nothing extra, since
    /// the pane number already does the work.
    public static func rows(_ tabs: [EditorTab]) -> [PickerItem] {
        let visible = tabs
            .filter { !$0.isCurrent }
            .sorted { $0.pane == $1.pane ? $0.index < $1.index : $0.pane < $1.pane }
        let paneCount = Set(tabs.map(\.pane)).count

        // Titles that repeat *within* a pane, counted over what is actually shown.
        var titlesPerPane: [Int: [String: Int]] = [:]
        for tab in visible {
            titlesPerPane[tab.pane, default: [:]][tab.title, default: 0] += 1
        }

        return visible.map { tab in
            var parts: [String] = []
            if paneCount > 1 { parts.append("pane \(tab.pane + 1)") }
            if titlesPerPane[tab.pane]?[tab.title, default: 0] ?? 0 > 1 {
                parts.append("tab \(tab.index + 1)")
            }
            // Worth saying: this file is already on screen somewhere else, so choosing it
            // moves you rather than opening anything.
            if tab.isActive { parts.append("showing") }
            return PickerItem(id: PickerTarget.tabID(pane: tab.pane, index: tab.index),
                              title: tab.title,
                              detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                              icon: .buffer)
        }
    }
}
