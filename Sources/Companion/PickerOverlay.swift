import AppKit
import AutographeCore

/// The picker window: a query line and a ranked list, centred over Xcode.
///
/// **It never becomes the key window.** A normal picker takes focus, which makes Xcode dim
/// and — the part that actually matters — leaves the editor's selection stale, so a picker
/// entry that transforms the selection has nothing to transform. Because we own the event
/// tap, keystrokes reach this list *before* Xcode sees them, and Xcode never learns it
/// stopped being typed into.
///
/// The cost is that we draw our own field and caret and handle every editing key by hand.
/// `PickerSession` in Core does that part, and is tested without a screen.
@MainActor
final class PickerOverlay {

    private let context: XcodeContext
    private var window: NSPanel?
    private var view: PickerView?

    init(context: XcodeContext) {
        self.context = context
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func present(_ session: PickerSession) {
        ensureWindow()
        view?.session = session
        view?.needsDisplay = true
        reposition()
        window?.orderFrontRegardless()
    }

    func update(_ session: PickerSession) {
        guard isVisible else { return }
        view?.session = session
        view?.needsDisplay = true
    }

    /// Re-centre on Xcode's window when it moves under us.
    func followWindow() {
        guard isVisible else { return }
        reposition()
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    /// Centred horizontally on Xcode's window and pinned near its top, the way Open Quickly
    /// and every other command palette sits. Falls back to the screen if Xcode will not say.
    private func reposition() {
        guard let window else { return }
        let width: CGFloat = 720
        let height: CGFloat = 380
        let target: NSRect
        if let ax = context.focusedWindowFrame() {
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let cocoa = NSRect(x: ax.minX, y: primaryTop - ax.minY - ax.height,
                               width: ax.width, height: ax.height)
            target = cocoa
        } else {
            target = NSScreen.main?.visibleFrame ?? .zero
        }
        let x = target.midX - width / 2
        let y = target.maxY - height - 120
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        view?.frame = window.contentView?.bounds ?? .zero
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 380),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // `.popover` rather than `.hudWindow`, plus an opaque backing colour.
        //
        // A heavily translucent panel takes its contrast from whatever is behind it, and
        // what is behind this one is Xcode — whose theme is independent of the system
        // appearance. In light mode over a dark editor the result was a grey haze with an
        // invisible breadcrumb. Backing the material with the window colour makes the
        // contrast a property of the panel rather than of the window under it, while the
        // material still supplies the blur at the edges.
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let backing = PanelBackingView()
        backing.autoresizingMask = [.width, .height]
        blur.addSubview(backing)

        let content = PickerView()
        backing.frame = blur.bounds
        blur.addSubview(content, positioned: .above, relativeTo: backing)
        panel.contentView = blur
        window = panel
        view = content
    }
}

@MainActor
final class PickerView: NSView {

    var session: PickerSession?

    override var isFlipped: Bool { true }

    private let padding: CGFloat = 16
    private let queryHeight: CGFloat = 42
    private let rowHeight: CGFloat = 28
    private let badgeSize: CGFloat = 17
    private let badgeGap: CGFloat = 10
    private let columnGap: CGFloat = 16
    private let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    private let queryFont = NSFont.systemFont(ofSize: 17)
    private let rowFont = NSFont.systemFont(ofSize: 13)
    private let matchFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private let detailFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Row colours, kept in one place because getting them wrong is what made the first
    /// version read as a christmas tree.
    ///
    /// Three rules. **Matched characters never use the accent colour on the selected row**,
    /// because the selection band is already accent-tinted and accent-on-accent has no
    /// contrast. **A disabled row gets no accent at all**, or an unavailable command looks
    /// livelier than an available one. And the unmatched part of a title stays at full
    /// label colour rather than dropping to secondary, so the highlight marks the match
    /// instead of the rest of the row receding.
    /// The one place a named tint becomes a colour.
    ///
    /// System colours rather than literals, so every one of these adapts to light and dark
    /// and to the user's accent colour without a second palette.
    private static func colour(for tint: IconTint) -> NSColor {
        switch tint {
        case .purple: .systemPurple
        case .blue:   .systemBlue
        case .teal:   .systemTeal
        case .green:  .systemGreen
        case .orange: .systemOrange
        case .pink:   .systemPink
        case .grey:   .secondaryLabelColor
        case .accent: .controlAccentColor
        }
    }

    private struct RowPalette {
        let text: NSColor
        let match: NSColor
        let detail: NSColor

        static func of(selected: Bool, enabled: Bool) -> RowPalette {
            switch (selected, enabled) {
            case (true, true):
                RowPalette(text: .labelColor, match: .labelColor, detail: .secondaryLabelColor)
            case (false, true):
                RowPalette(text: .labelColor, match: .controlAccentColor, detail: .tertiaryLabelColor)
            case (true, false):
                RowPalette(text: .secondaryLabelColor, match: .secondaryLabelColor, detail: .tertiaryLabelColor)
            case (false, false):
                RowPalette(text: .tertiaryLabelColor, match: .tertiaryLabelColor, detail: .quaternaryLabelColor)
            }
        }
    }

    var visibleRowCount: Int { Int((bounds.height - padding * 2 - queryHeight) / rowHeight) }

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }

        // Title, then the query line with our own caret.
        // Upper-cased and at secondary rather than tertiary: at 11pt a tertiary label on a
        // HUD material is legible in a mock-up and invisible on a real screen.
        NSAttributedString(string: session.title.uppercased(), attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
        ]).draw(at: NSPoint(x: padding, y: padding - 4))

        let query = NSAttributedString(string: session.query, attributes: [
            .font: queryFont, .foregroundColor: NSColor.labelColor,
        ])
        let queryY = padding + 12
        query.draw(at: NSPoint(x: padding, y: queryY))

        // A drawn caret, because there is no real text field here to blink one for us.
        let caretX = padding + query.size().width + 1
        NSColor.controlAccentColor.setFill()
        NSRect(x: caretX, y: queryY + 2, width: 2, height: queryFont.pointSize + 2).fill()

        if session.query.isEmpty {
            NSAttributedString(string: "type to filter", attributes: [
                .font: queryFont, .foregroundColor: NSColor.tertiaryLabelColor,
            ]).draw(at: NSPoint(x: caretX + 8, y: queryY))
        }

        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: padding + queryHeight, width: bounds.width, height: 1).fill()

        // Scroll the window of rows so the selection is always shown.
        let capacity = max(1, visibleRowCount)
        let first = max(0, min(session.selection - capacity / 2, max(0, session.rows.count - capacity)))
        let slice = session.rows.dropFirst(first).prefix(capacity)

        var y = padding + queryHeight + 6
        for (offset, row) in slice.enumerated() {
            let index = first + offset
            let isSelected = index == session.selection

            let palette = RowPalette.of(selected: isSelected, enabled: row.item.isEnabled)

            if isSelected {
                // Softer than a solid accent band, and rounded so it reads as a row rather
                // than a stripe across the window.
                let band = NSRect(x: 8, y: y - 4, width: bounds.width - 16, height: rowHeight)
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
            }

            // The badge: a rounded square with a letter, the shape Xcode uses in its own
            // completion list, tinted by what the row is.
            var textX = padding
            if let icon = row.item.icon {
                let box = NSRect(x: padding, y: y - 1, width: badgeSize, height: badgeSize)
                let tint = Self.colour(for: icon.tint)
                let enabled = row.item.isEnabled
                tint.withAlphaComponent(enabled ? 0.22 : 0.10).setFill()
                NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                let glyph = NSAttributedString(string: icon.glyph, attributes: [
                    .font: badgeFont,
                    .foregroundColor: enabled ? tint : tint.withAlphaComponent(0.45),
                ])
                let size = glyph.size()
                glyph.draw(at: NSPoint(x: box.midX - size.width / 2,
                                       y: box.midY - size.height / 2))
                textX = padding + badgeSize + badgeGap
            }

            let title = NSMutableAttributedString(string: row.item.title, attributes: [
                .font: rowFont, .foregroundColor: palette.text,
            ])
            // Bold the characters the query matched. Indices come from the matcher and are
            // in characters, so map them through to UTF-16 before touching an NSRange:
            // a path with an emoji or an accent would otherwise attribute the wrong glyph.
            let utf16 = Array(row.item.title)
            for i in row.matched where i < utf16.count {
                let start = String(utf16[0..<i]).utf16.count
                let length = String(utf16[i]).utf16.count
                title.addAttributes([.font: matchFont, .foregroundColor: palette.match],
                                    range: NSRange(location: start, length: length))
            }
            // Measure the detail first, then give the title whatever is left. Drawing the
            // title unbounded lets a long line run underneath the file column, and the two
            // overlap into an unreadable smear.
            let detail = row.item.detail.map {
                NSAttributedString(string: $0, attributes: [
                    .font: detailFont, .foregroundColor: palette.detail,
                ])
            }
            let detailWidth = detail.map { $0.size().width + columnGap } ?? 0
            let available = max(40, bounds.width - padding - textX - detailWidth)

            let truncation = NSMutableParagraphStyle()
            truncation.lineBreakMode = .byTruncatingTail
            title.addAttribute(.paragraphStyle, value: truncation,
                               range: NSRange(location: 0, length: title.length))
            title.draw(with: NSRect(x: textX, y: y, width: available, height: rowHeight),
                       options: [.usesLineFragmentOrigin])

            if let detail {
                detail.draw(at: NSPoint(x: bounds.width - padding - detail.size().width, y: y + 2))
            }
            y += rowHeight
        }

        if session.rows.isEmpty {
            NSAttributedString(string: "no matches", attributes: [
                .font: rowFont, .foregroundColor: NSColor.secondaryLabelColor,
            ]).draw(at: NSPoint(x: padding, y: padding + queryHeight + 8))
        }

        // A count, so a long list does not feel bottomless.
        let count = NSAttributedString(string: "\(session.rows.count)", attributes: [
            .font: detailFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        count.draw(at: NSPoint(x: bounds.width - padding - count.size().width, y: padding - 4))
    }
}
