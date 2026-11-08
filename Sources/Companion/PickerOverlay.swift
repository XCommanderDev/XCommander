import AppKit
import XCommanderCore

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

    /// How wide the preview pane is.
    ///
    /// **Never changes because the selection moved** — a pane that appeared and disappeared as
    /// the cursor crossed rows would be the most jarring thing this feature could do, so the
    /// width is a property of the picker and not of the row.
    ///
    /// **Does change when the user resizes Xcode**, which is a different thing entirely: they
    /// caused it, the cause is obvious, and every other window on the machine reflows. A panel
    /// that instead kept a width its window can no longer hold — overhanging Xcode and pinned
    /// against the screen edge — is tidy in principle and wrong on screen.
    private(set) var previewWidth: CGFloat = 0

    /// Adopt a new pane width, for a window that changed shape under an open picker.
    ///
    /// - Returns: whether it changed, so the caller only re-requests a preview when it did.
    @discardableResult
    func setPreviewWidth(_ width: CGFloat) -> Bool {
        guard isVisible, width != previewWidth else { return false }
        previewWidth = width
        view?.previewWidth = width
        if width == 0 { view?.preview = nil }
        view?.needsDisplay = true
        return true
    }

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

    /// Characters of the pane that are visible, for scrolling a far-right match into view.
    var previewColumns: Int { view?.previewColumnCapacity ?? 0 }

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

        // Always dark, and backed near-opaque, for the reasons given on the which-key panel:
        // the backdrop is Xcode, and the backdrop must not decide whether this is legible.
        panel.appearance = NSAppearance(named: .darkAqua)
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let backing = PanelBackingView()
        backing.colour = Theme.pickerBackground
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
    /// Three rules. **Matched characters are marked by weight and an underline, not by a
    /// colour**, so the mark survives the solid blue selection band, where any tint would
    /// fight it. **A disabled row gets nothing bright at all**, or an unavailable command
    /// looks livelier than an available one. And the unmatched part of a title stays at full
    /// text colour rather than dropping to dim, so the highlight marks the match instead of
    /// the rest of the row receding.
    private struct RowPalette {
        let text: NSColor
        let match: NSColor
        let detail: NSColor

        static func of(selected: Bool, enabled: Bool) -> RowPalette {
            switch (selected, enabled) {
            case (true, true):
                RowPalette(text: Theme.textStrong, match: Theme.textStrong,
                           detail: Theme.textStrong.withAlphaComponent(0.75))
            case (false, true):
                RowPalette(text: Theme.text, match: Theme.textStrong, detail: Theme.textFaint)
            case (true, false):
                RowPalette(text: Theme.textStrong.withAlphaComponent(0.6),
                           match: Theme.textStrong.withAlphaComponent(0.6),
                           detail: Theme.textStrong.withAlphaComponent(0.45))
            case (false, false):
                RowPalette(text: Theme.textFaint, match: Theme.textFaint, detail: Theme.textFaint)
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

    /// How many characters of the pane are visible. The font is monospaced, so one advance
    /// width answers it — and the gutter is allowed for generously, since guessing a few
    /// columns short only scrolls the match slightly further in than it needed to be.
    var previewColumnCapacity: Int {
        guard previewWidth > 0 else { return 0 }
        let advance = previewFont.maximumAdvancement.width
        guard advance > 0 else { return 0 }
        let usable = previewWidth - padding * 2 - 44
        return max(0, Int(usable / advance))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let session else { return }

        // Title, then the query line with our own caret.
        // Upper-cased and at secondary rather than tertiary: at 11pt a tertiary label on a
        // HUD material is legible in a mock-up and invisible on a real screen.
        NSAttributedString(string: session.title.uppercased(), attributes: [
            .font: titleFont,
            .foregroundColor: Theme.textDim,
            .kern: 0.6,
        ]).draw(at: NSPoint(x: padding, y: padding - 4))

        let query = NSAttributedString(string: session.query, attributes: [
            .font: queryFont, .foregroundColor: Theme.textStrong,
        ])
        let queryY = padding + 12
        query.draw(at: NSPoint(x: padding, y: queryY))

        // A drawn caret, because there is no real text field here to blink one for us.
        let caretX = padding + query.size().width + 1
        Theme.selection.setFill()
        NSRect(x: caretX, y: queryY + 2, width: 2, height: queryFont.pointSize + 2).fill()

        if session.query.isEmpty {
            NSAttributedString(string: "type to filter", attributes: [
                .font: queryFont, .foregroundColor: Theme.textFaint,
            ]).draw(at: NSPoint(x: caretX + 8, y: queryY))
        }

        Theme.hairline.setFill()
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
                // A solid band, the way Open Quickly marks its row, rounded so it reads as a
                // row rather than a stripe across the window.
                let band = NSRect(x: 8, y: y - 4, width: listWidth - 16, height: rowHeight)
                Theme.selection.setFill()
                NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
            }

            // The badge: a rounded square with a letter, the shape Xcode uses in its own
            // completion list, tinted by what the row is.
            var textX = padding
            if let icon = row.item.icon {
                drawBadge(icon, in: NSRect(x: padding, y: y - 1,
                                           width: badgeSize, height: badgeSize),
                          enabled: row.item.isEnabled, font: badgeFont, onSelection: isSelected)
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
                title.addAttributes([.font: matchFont, .foregroundColor: palette.match,
                                     .underlineStyle: NSUnderlineStyle.single.rawValue],
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
                .font: rowFont, .foregroundColor: Theme.textDim,
            ]).draw(at: NSPoint(x: padding, y: padding + queryHeight + 8))
        }

        // A count, so a long list does not feel bottomless.
        let count = NSAttributedString(string: "\(session.rows.count)", attributes: [
            .font: detailFont, .foregroundColor: Theme.textFaint,
        ])
        count.draw(at: NSPoint(x: listWidth - padding - count.size().width, y: padding - 4))
    }

    // MARK: - the preview pane

    /// The band below the list. Its frame is always drawn when this picker has one, even when
    /// there is nothing to put in it: a pane that collapses on a row with no preview would move
    /// the layout under the cursor, which is the thing this feature must never do.
    private func drawPreview() {
        guard previewWidth > 0 else { return }

        Theme.hairline.setFill()
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
                // The selection blue, softened, with a solid edge: the same idea as the
                // selected row, quiet enough to read the code through.
                let band = NSRect(x: rect.minX + 6, y: y - 2,
                                  width: rect.width - 12, height: lineHeight)
                Theme.focusLine.setFill()
                NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4).fill()
                Theme.selection.setFill()
                NSRect(x: band.minX, y: band.minY, width: 2, height: band.height).fill()
            }

            let gutter = NSAttributedString(string: "\(line.number)", attributes: [
                .font: gutterFont,
                .foregroundColor: isFocus ? Theme.text : Theme.textFaint,
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
                .font: gutterFont, .foregroundColor: Theme.textFaint,
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
        let base = dimmed ? Theme.textDim : Theme.text
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
                (dimmed ? Theme.searchMark.withAlphaComponent(0.16) : Theme.searchMark).setFill()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            }
        }

        for span in line.spans {
            let range = NSRange(location: span.start, length: span.length)
            guard range.location >= 0, range.location + range.length <= length else { continue }
            var colour = Theme.colour(for: span.role)
            // Away from the focus line the colour recedes rather than disappears: the shape of
            // the code stays readable while the answer stays the brightest thing in the pane.
            if dimmed { colour = colour.withAlphaComponent(0.5) }
            attributed.addAttribute(.foregroundColor, value: colour, range: range)
        }

        // Text under the mark goes back to plain white, for the same reason the row list marks
        // matched characters with weight rather than colour: a syntax colour over a tinted box
        // is two marks fighting, and the one that loses is the word you searched for. The box
        // says "here"; the text just has to be readable.
        if let highlight = line.highlight, highlight.upperBound <= length {
            attributed.addAttribute(.foregroundColor, value: Theme.textStrong,
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
            .foregroundColor: dimmed ? Theme.textFaint : Theme.textDim,
        ])
        attributed.draw(at: NSPoint(x: rect.minX + padding, y: rect.minY + previewPadding))
    }

    /// The rounded, tinted square Xcode uses in its own completion list.
    ///
    /// Shared by the row list and the outline pane deliberately: the pane has to read as part
    /// of this window, and two copies of this drawing would drift the first time one is
    /// touched.
    ///
    /// On the selected row the badge turns white: every tint is a colour placed against dark
    /// grey, and on the blue band half of them — the blues and teals first — disappear.
    private func drawBadge(_ icon: RowIcon, in box: NSRect, enabled: Bool, font: NSFont,
                           onSelection: Bool = false) {
        let tint = onSelection ? Theme.textStrong : Theme.colour(for: icon.tint)
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
                .foregroundColor: Theme.text,
            ])
            name.draw(at: NSPoint(x: nameX, y: y + 1))

            // The line number sits where the list puts its detail column, right-aligned, so
            // the eye finds it in the same place in both halves of the window.
            let number = NSAttributedString(string: "\(node.line)", attributes: [
                .font: gutterFont, .foregroundColor: Theme.textFaint,
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
                        .foregroundColor: Theme.textDim,
                        .paragraphStyle: truncation,
                    ]).draw(with: NSRect(x: x, y: y + 2, width: available, height: outlineRowHeight),
                            options: [.usesLineFragmentOrigin])
                }
            }
            y += outlineRowHeight
        }

        if total > shown.count {
            let more = NSAttributedString(string: "+\(total - shown.count) more", attributes: [
                .font: gutterFont, .foregroundColor: Theme.textFaint,
            ])
            more.draw(at: NSPoint(x: rect.minX + padding, y: y + 2))
        }
    }
}
