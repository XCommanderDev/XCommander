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

    /// How wide the preview pane is for this presentation, decided once when the picker opens
    /// and never changed while it is open.
    ///
    /// **The panel must not resize under the cursor.** A pane that appeared and disappeared as
    /// the selection moved would be the most jarring thing this feature could do, so the width
    /// is a property of the *picker*, not of the row.
    private(set) var previewWidth: CGFloat = 0

    func present(_ session: PickerSession) {
        present(session, previewWidth: 0)
    }

    /// Present with a preview pane of a given width, which is fixed for this presentation.
    func present(_ session: PickerSession, previewWidth: CGFloat) {
        ensureWindow()
        self.previewWidth = previewWidth
        view?.previewWidth = previewWidth
        view?.preview = previewWidth > 0 ? .failure(.loading) : nil
        view?.session = session
        view?.needsDisplay = true
        reposition()
        window?.orderFrontRegardless()
    }

    /// The pane's content changed; the panel's shape did not.
    func showPreview(_ result: PreviewResult?) {
        guard isVisible, previewWidth > 0 else { return }
        view?.preview = result
        view?.needsDisplay = true
    }

    /// How many lines of source the pane has room for, which is what the loader slices to.
    var previewCapacity: Int { view?.previewLineCapacity ?? 0 }

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
        let width: CGFloat = Self.listWidth + previewWidth
        let height: CGFloat = Self.panelHeight
        let target: NSRect
        if let ax = context.focusedWindowFrame() {
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            let cocoa = NSRect(x: ax.minX, y: primaryTop - ax.minY - ax.height,
                               width: ax.width, height: ax.height)
            target = cocoa
        } else {
            target = NSScreen.main?.visibleFrame ?? .zero
        }
        // Clamped to the screen, which matters more now the panel is 1340pt wide with a pane
        // attached. Its width is fixed for the life of the presentation — it must not resize
        // under the hand using it — so Xcode narrowed *while the picker is open* leaves the
        // panel overhanging the window, which is fine. Leaving the screen is not.
        let visible = (NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main)?
            .visibleFrame ?? target
        let placed = PanelPlacement.frame(
            width: Double(width), height: Double(height), topInset: 120,
            centredOn: PaneRect(x: Double(target.minX), y: Double(target.minY),
                                width: Double(target.width), height: Double(target.height)),
            within: PaneRect(x: Double(visible.minX), y: Double(visible.minY),
                             width: Double(visible.width), height: Double(visible.height)))
        window.setFrame(NSRect(x: placed.x, y: placed.y,
                               width: placed.width, height: placed.height), display: true)
        view?.frame = window.contentView?.bounds ?? .zero
    }

    /// Exactly what the panel was before there was a preview.
    ///
    /// The pane is added to the *right* of this rather than carved out of it, so the list keeps
    /// its width and its row count whether the pane is showing or not — which is also why
    /// `visibleRowCount` and `PickerSession.pageSize` can never come to disagree.
    static let listWidth: CGFloat = 720
    static let panelHeight: CGFloat = 380

    private func ensureWindow() {
        guard window == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.listWidth,
                                                height: Self.panelHeight),
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

    /// What the pane draws, or nil when this picker has no pane at all.
    var preview: PreviewResult?
    /// Fixed for the life of a presentation. See `PickerOverlay.previewWidth`.
    var previewWidth: CGFloat = 0

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

    private let previewFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    private let previewPadding: CGFloat = 10
    private let outlineRowHeight: CGFloat = 18
    private let outlineBadgeSize: CGFloat = 14
    private let outlineIndent: CGFloat = 14
    private let outlineBadgeFont = NSFont.systemFont(ofSize: 8, weight: .bold)
    private let outlineNameFont = NSFont.systemFont(ofSize: 11.5)
    private let outlineNameBoldFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private let outlineSummaryFont = NSFont.systemFont(ofSize: 10.5)

    /// The list's own width, which does not change when a preview is showing: the pane is
    /// added beside the list rather than taken out of it.
    private var listWidth: CGFloat { bounds.width - previewWidth }

    var visibleRowCount: Int { Int((bounds.height - padding * 2 - queryHeight) / rowHeight) }

    /// How many source lines fit in the pane. The loader slices to exactly this, so nothing is
    /// read that cannot be drawn.
    var previewLineCapacity: Int {
        guard previewWidth > 0 else { return 0 }
        let usable = bounds.height - previewPadding * 2
        return max(0, Int(usable / previewLineHeight))
    }

    private var previewLineHeight: CGFloat { ceil(previewFont.boundingRectForFont.height) + 2 }

    /// One colour per role. **System colours, never literals**, so the pane follows light and
    /// dark and the user's accent without a second palette — and so it never pretends to be
    /// Xcode's theme, which we cannot read and should not imitate badly.
    private static func colour(for role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword:    .systemPink
        case .string:     .systemRed
        case .number:     .systemOrange
        case .comment:    .systemGreen
        case .docComment: .systemGray
        case .typeName:   .systemPurple
        case .attribute:  .systemTeal
        case .plain:      .labelColor
        }
    }

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
        NSRect(x: 0, y: padding + queryHeight, width: listWidth, height: 1).fill()

        drawPreview()

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
                let band = NSRect(x: 8, y: y - 4, width: listWidth - 16, height: rowHeight)
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
            }

            // The badge: a rounded square with a letter, the shape Xcode uses in its own
            // completion list, tinted by what the row is.
            var textX = padding
            if let icon = row.item.icon {
                drawBadge(icon, in: NSRect(x: padding, y: y - 1,
                                           width: badgeSize, height: badgeSize),
                          enabled: row.item.isEnabled, font: badgeFont)
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
            let available = max(40, listWidth - padding - textX - detailWidth)

            let truncation = NSMutableParagraphStyle()
            truncation.lineBreakMode = .byTruncatingTail
            title.addAttribute(.paragraphStyle, value: truncation,
                               range: NSRange(location: 0, length: title.length))
            title.draw(with: NSRect(x: textX, y: y, width: available, height: rowHeight),
                       options: [.usesLineFragmentOrigin])

            if let detail {
                detail.draw(at: NSPoint(x: listWidth - padding - detail.size().width, y: y + 2))
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
        count.draw(at: NSPoint(x: listWidth - padding - count.size().width, y: padding - 4))
    }

    // MARK: - the preview pane

    /// The band below the list. Its frame is always drawn when this picker has one, even when
    /// there is nothing to put in it: a pane that collapses on a row with no preview would move
    /// the layout under the cursor, which is the thing this feature must never do.
    private func drawPreview() {
        guard previewWidth > 0 else { return }

        NSColor.separatorColor.setFill()
        NSRect(x: listWidth, y: 0, width: 1, height: bounds.height).fill()

        let body = NSRect(x: listWidth + 1, y: 0,
                          width: previewWidth - 1, height: bounds.height)
        switch preview {
        case .success(.text(let text)):
            draw(text, in: body)
        case .success(.outline(let nodes)):
            draw(outline: nodes, in: body)
        case .failure(let reason):
            draw(message: reason.message, in: body, dimmed: reason == .loading)
        case nil:
            break
        }
    }

    /// Source, with a line-number gutter and the focus line marked.
    ///
    /// Deliberately dumb: every offset, every tab and every colour run was resolved in Core by
    /// `PreviewBuilder`, so this walks lines and spans and does no arithmetic of its own.
    private func draw(_ text: TextPreview, in rect: NSRect) {
        guard !text.lines.isEmpty else {
            draw(message: "empty file", in: rect, dimmed: true)
            return
        }
        let lineHeight = previewLineHeight
        // The gutter is sized to the largest number it will show, so the code does not shuffle
        // sideways as the window moves down a long file.
        let widest = NSAttributedString(string: "\(text.firstLine + text.lines.count)",
                                        attributes: [.font: gutterFont]).size().width
        let gutterWidth = ceil(widest) + 8
        let codeX = rect.minX + padding + gutterWidth + 8
        // Only dim the surroundings when there is a focus line to set them against.
        let hasFocus = text.focusLine != nil

        var y = rect.minY + previewPadding
        for line in text.lines {
            let isFocus = line.number == text.focusLine

            if isFocus {
                // The same band the selected row uses, so the two marks read as one idea.
                let band = NSRect(x: rect.minX + 6, y: y - 2,
                                  width: rect.width - 12, height: lineHeight)
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4).fill()
            }

            let gutter = NSAttributedString(string: "\(line.number)", attributes: [
                .font: gutterFont,
                .foregroundColor: isFocus ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ])
            gutter.draw(at: NSPoint(x: rect.minX + padding + gutterWidth - gutter.size().width,
                                    y: y + 1))

            draw(line, at: NSPoint(x: codeX, y: y),
                 width: rect.maxX - codeX - padding,
                 dimmed: hasFocus && !isFocus, height: lineHeight)
            y += lineHeight
        }

        if text.hasMore {
            let more = NSAttributedString(string: "⋯", attributes: [
                .font: gutterFont, .foregroundColor: NSColor.quaternaryLabelColor,
            ])
            more.draw(at: NSPoint(x: rect.maxX - padding - more.size().width,
                                  y: rect.maxY - previewPadding - lineHeight))
        }
    }

    /// One line, with its colour runs applied.
    ///
    /// Truncated and never wrapped: one 400-character line must not eat the pane.
    private func draw(_ line: PreviewLine, at origin: NSPoint, width: CGFloat,
                      dimmed: Bool, height: CGFloat) {
        let base = dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor
        let attributed = NSMutableAttributedString(string: line.text, attributes: [
            .font: previewFont, .foregroundColor: base,
        ])
        let length = attributed.length

        // The searched-for text, marked the way every other editor's picker marks it. Drawn
        // as a background so it reads as "this is the hit" rather than as another syntax role.
        if let highlight = line.highlight, highlight.upperBound <= length {
            let before = attributed.attributedSubstring(
                from: NSRange(location: 0, length: highlight.lowerBound)).size().width
            let hit = attributed.attributedSubstring(
                from: NSRange(location: highlight.lowerBound, length: highlight.count)).size().width
            if origin.x + before < origin.x + width {
                let box = NSRect(x: origin.x + before - 1, y: origin.y,
                                 width: min(hit + 2, width - before), height: height - 1)
                NSColor.systemYellow.withAlphaComponent(dimmed ? 0.18 : 0.32).setFill()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            }
        }

        for span in line.spans {
            let range = NSRange(location: span.start, length: span.length)
            guard range.location >= 0, range.location + range.length <= length else { continue }
            var colour = Self.colour(for: span.role)
            // Away from the focus line the colour recedes rather than disappears: the shape of
            // the code stays readable while the answer stays the brightest thing in the pane.
            if dimmed { colour = colour.withAlphaComponent(0.5) }
            attributed.addAttribute(.foregroundColor, value: colour, range: range)
        }

        // Text under the mark goes back to label colour, for the same reason the row list
        // drops the accent off matched characters on a selected row: a syntax colour over a
        // tinted box is two marks fighting, and the one that loses is the word you searched
        // for. The box says "here"; the text just has to be readable.
        if let highlight = line.highlight, highlight.upperBound <= length {
            attributed.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                    range: NSRange(location: highlight.lowerBound,
                                                   length: highlight.count))
        }

        let truncation = NSMutableParagraphStyle()
        truncation.lineBreakMode = .byTruncatingTail
        attributed.addAttribute(.paragraphStyle, value: truncation,
                                range: NSRange(location: 0, length: length))
        attributed.draw(with: NSRect(x: origin.x, y: origin.y, width: width, height: height),
                        options: [.usesLineFragmentOrigin])
    }

    private func draw(message: String, in rect: NSRect, dimmed: Bool) {
        let attributed = NSAttributedString(string: message, attributes: [
            .font: rowFont,
            .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
        ])
        attributed.draw(at: NSPoint(x: rect.minX + padding, y: rect.minY + previewPadding))
    }

    /// The rounded, tinted square Xcode uses in its own completion list.
    ///
    /// Shared by the row list and the outline pane deliberately: the pane has to read as part
    /// of this window, and two copies of this drawing would drift the first time one is
    /// touched.
    private func drawBadge(_ icon: RowIcon, in box: NSRect, enabled: Bool, font: NSFont) {
        let tint = Self.colour(for: icon.tint)
        tint.withAlphaComponent(enabled ? 0.22 : 0.10).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let glyph = NSAttributedString(string: icon.glyph, attributes: [
            .font: font,
            .foregroundColor: enabled ? tint : tint.withAlphaComponent(0.45),
        ])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }

    /// What is *in* a file, rather than its first forty lines.
    ///
    /// The answer to "is this the file I meant" is its declarations, and — because sourcekitd
    /// gives us the documentation range for each one — the first sentence of what each is for.
    /// That last column is the part a Vim picker cannot show: a syntactic tree does not know
    /// that the lines above a function belong to it.
    private func draw(outline nodes: [OutlineNode], in rect: NSRect) {
        let total = OutlineNode.flatten(nodes).count
        guard total > 0 else {
            draw(message: "no declarations", in: rect, dimmed: true)
            return
        }
        let capacity = max(0, Int((rect.height - previewPadding * 2) / outlineRowHeight))
        guard capacity > 0 else { return }
        // Keep one row back for the "+N more" line when the file does not fit.
        let shown = OutlineNode.fitting(nodes, capacity: total > capacity ? capacity - 1 : capacity)

        var y = rect.minY + previewPadding
        for (node, depth) in shown {
            let indent = rect.minX + padding + CGFloat(min(depth, 3)) * outlineIndent
            // Always at full tint. `enabled` means "you cannot use this row" in the list above,
            // and a badge dimmed for being internal says exactly the wrong thing — in an app
            // target nothing is public, so the whole outline came out looking disabled.
            drawBadge(node.icon,
                      in: NSRect(x: indent, y: y + 1, width: outlineBadgeSize, height: outlineBadgeSize),
                      enabled: true, font: outlineBadgeFont)
            let nameX = indent + outlineBadgeSize + 7

            // Public reads at full weight, so the shape of a library's API is visible without
            // reading the names — but everything stays at label colour, because in an app
            // target nothing is public and a whole file at secondary is just faint.
            let name = NSAttributedString(string: node.name, attributes: [
                .font: node.isPublic ? outlineNameBoldFont : outlineNameFont,
                .foregroundColor: NSColor.labelColor,
            ])
            name.draw(at: NSPoint(x: nameX, y: y + 1))

            // The line number sits where the list puts its detail column, right-aligned, so
            // the eye finds it in the same place in both halves of the window.
            let number = NSAttributedString(string: "\(node.line)", attributes: [
                .font: gutterFont, .foregroundColor: NSColor.quaternaryLabelColor,
            ])
            let numberX = rect.maxX - padding - number.size().width
            number.draw(at: NSPoint(x: numberX, y: y + 2))

            if let summary = node.summary {
                let x = nameX + name.size().width + 8
                let available = numberX - x - 8
                if available > 40 {
                    let truncation = NSMutableParagraphStyle()
                    truncation.lineBreakMode = .byTruncatingTail
                    NSAttributedString(string: summary, attributes: [
                        .font: outlineSummaryFont,
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: truncation,
                    ]).draw(with: NSRect(x: x, y: y + 2, width: available, height: outlineRowHeight),
                            options: [.usesLineFragmentOrigin])
                }
            }
            y += outlineRowHeight
        }

        if total > shown.count {
            let more = NSAttributedString(string: "+\(total - shown.count) more", attributes: [
                .font: gutterFont, .foregroundColor: NSColor.quaternaryLabelColor,
            ])
            more.draw(at: NSPoint(x: rect.minX + padding, y: y + 2))
        }
    }
}
