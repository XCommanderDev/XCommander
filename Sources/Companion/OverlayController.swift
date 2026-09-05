import AppKit
import CompanionCore

/// The which-key panel: a borderless, non-activating window pinned to the bottom inner
/// edge of Xcode's frontmost window.
///
/// Two details make it feel attached rather than bolted on. It is positioned against
/// **Xcode's window frame**, read over Accessibility, not against the screen. And it
/// appears after a **cancellable delay**, so anyone who types the whole sequence quickly
/// never sees it at all. That delay is the difference between a helpful tool and one that
/// flashes at you all day.
@MainActor
final class OverlayController {

    /// Long enough that a fluent sequence never triggers it, short enough that a pause
    /// feels answered rather than ignored.
    var delay: TimeInterval = 0.35

    private let context: XcodeContext
    private var window: NSPanel?
    private var view: WhichKeyView?
    private var pendingShow: Timer?
    private var queued: WhichKeyPanel?

    init(context: XcodeContext) {
        self.context = context
    }

    /// Show this panel once the delay elapses, unless something cancels first.
    ///
    /// Called on every key of a sequence. The timer is only started once: refining from
    /// `SPC` to `SPC b` updates the content and leaves the clock running, so the panel
    /// does not keep pushing its own appearance further away.
    func present(_ panel: WhichKeyPanel) {
        if window?.isVisible == true {
            render(panel)
            return
        }
        guard pendingShow == nil else {
            queued = panel
            return
        }
        queued = panel
        pendingShow = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.queued else { return }
                self.pendingShow = nil
                self.render(panel)
                self.show()
            }
        }
    }

    func dismiss() {
        pendingShow?.invalidate()
        pendingShow = nil
        queued = nil
        window?.orderOut(nil)
    }

    private func show() {
        guard let window else { return }
        reposition()
        window.orderFrontRegardless()
    }

    private func render(_ panel: WhichKeyPanel) {
        ensureWindow()
        view?.panel = panel
        view?.needsDisplay = true
        reposition()
    }

    /// AX reports top-left origin coordinates; Cocoa windows are bottom-left. The flip is
    /// against the primary screen's height, not the screen the window happens to be on.
    private func reposition() {
        guard let window, let view else { return }
        guard let axFrame = context.focusedWindowFrame() else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = NSRect(x: axFrame.minX,
                           y: primaryTop - axFrame.minY - axFrame.height,
                           width: axFrame.width,
                           height: axFrame.height)
        let inset: CGFloat = 12
        let height = view.preferredHeight(forWidth: cocoa.width - inset * 2)
        window.setFrame(NSRect(x: cocoa.minX + inset,
                               y: cocoa.minY + inset,
                               width: cocoa.width - inset * 2,
                               height: height),
                        display: true)
        view.frame = window.contentView?.bounds ?? .zero
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // It must never take the keyboard: Xcode has to stay first responder while the
        // panel is up, or the next key of the sequence goes nowhere.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // `.fullScreenAuxiliary` plus `.canJoinAllSpaces` is what lets it appear over a
        // full-screen Xcode, which an ordinary floating window will not do.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let content = WhichKeyView()
        blur.addSubview(content)
        panel.contentView = blur

        self.window = panel
        self.view = content
    }
}

/// Draws the breadcrumb and the rows. AppKit drawing rather than SwiftUI: the panel is
/// shown and hidden on a keystroke path, and there is nothing here worth a hosting view.
@MainActor
final class WhichKeyView: NSView {

    var panel: WhichKeyPanel = WhichKeyPanel(breadcrumb: "", rows: [])

    override var isFlipped: Bool { true }

    private let rowHeight: CGFloat = 22
    private let padding: CGFloat = 14
    private let columnGap: CGFloat = 24
    private let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private let titleFont = NSFont.systemFont(ofSize: 12)
    /// Monospaced so the modifier glyphs line up, and tertiary rather than quaternary:
    /// quaternary on a HUD material is legible in a design tool and invisible on screen.
    private let shortcutFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Lay the rows out in as many columns as fit, the way which-key does, so a group with
    /// twenty commands is still one glance rather than a scroll.
    private func columns(forWidth width: CGFloat) -> (count: Int, rowsPerColumn: Int, columnWidth: CGFloat) {
        let usable = max(width - padding * 2, 100)
        let widest = panel.rows.reduce(CGFloat(60)) { widest, row in
            max(widest, measure(row).width)
        }
        let columnWidth = widest + columnGap
        let count = max(1, min(panel.rows.count, Int(usable / columnWidth)))
        let rowsPerColumn = Int((Double(panel.rows.count) / Double(count)).rounded(.up))
        return (count, max(rowsPerColumn, 1), columnWidth)
    }

    private func measure(_ row: WhichKeyRow) -> CGSize {
        let key = NSAttributedString(string: row.key, attributes: [.font: keyFont])
        let title = NSAttributedString(string: row.label, attributes: [.font: titleFont])
        let shortcut = row.shortcut.map {
            NSAttributedString(string: $0, attributes: [.font: shortcutFont])
        }
        return CGSize(width: key.size().width + 14 + title.size().width
                             + (shortcut.map { $0.size().width + 12 } ?? 0),
                      height: rowHeight)
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let layout = columns(forWidth: width)
        return padding * 2 + 20 + CGFloat(layout.rowsPerColumn) * rowHeight
    }

    override func draw(_ dirtyRect: NSRect) {
        let breadcrumb = NSAttributedString(string: panel.breadcrumb, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        breadcrumb.draw(at: NSPoint(x: padding, y: padding))

        let layout = columns(forWidth: bounds.width)
        let top = padding + 20

        for (i, row) in panel.rows.enumerated() {
            let column = i / layout.rowsPerColumn
            let indexInColumn = i % layout.rowsPerColumn
            var x = padding + CGFloat(column) * layout.columnWidth
            let y = top + CGFloat(indexInColumn) * rowHeight

            let key = NSAttributedString(string: row.key, attributes: [
                .font: keyFont, .foregroundColor: NSColor.labelColor,
            ])
            key.draw(at: NSPoint(x: x, y: y))
            x += key.size().width + 6

            let arrow = NSAttributedString(string: "→", attributes: [
                .font: titleFont, .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            arrow.draw(at: NSPoint(x: x, y: y))
            x += arrow.size().width + 6

            // Groups in the accent colour, commands in the label colour: the one visual
            // distinction that tells you whether this key ends the sequence or continues it.
            let title = NSAttributedString(string: row.label, attributes: [
                .font: titleFont,
                .foregroundColor: row.isGroup ? NSColor.controlAccentColor : NSColor.labelColor,
            ])
            title.draw(at: NSPoint(x: x, y: y))
            x += title.size().width + 8

            if let shortcut = row.shortcut {
                NSAttributedString(string: shortcut, attributes: [
                    .font: shortcutFont, .foregroundColor: NSColor.tertiaryLabelColor,
                ]).draw(at: NSPoint(x: x, y: y + 1))
            }
        }
    }
}
