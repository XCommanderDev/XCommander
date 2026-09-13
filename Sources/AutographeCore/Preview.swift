import Foundation

/// The preview pane, as logic.
///
/// The pane answers **the question its picker left open**, which is why this is not one shape.
/// A search hit and a symbol leave "is this the right line?", so they want text in context. A
/// file leaves "is this the right file?", and the honest answer to that is what is *in* it —
/// its outline — rather than its first forty lines, which are imports and a licence header.
///
/// Everything here is decidable without a screen, so all of it is here and tested, and the
/// drawing in `PickerView` only paints what these types describe.

// MARK: - what a row wants shown

/// Which of the two shapes a picker's rows want. Policy, kept next to `PickerKind`.
public enum PreviewStyle: Hashable, Sendable {
    case text, outline, none
}

/// What a selected row wants previewed. `nil` — rather than a `.none` case — is how a row with
/// nothing to show says so, because that is the common answer and it should not need unwrapping
/// at every call site.
public enum PreviewRequest: Hashable, Sendable {
    /// Lines of a file, centred on `focusLine` when the row named one.
    ///
    /// `highlight` is the byte range of the matched text *within that line*, which is what
    /// `SearchMatch` already records — so the pane can mark the term you searched for, the way
    /// every other editor's picker does, rather than leaving you to find it.
    case text(path: String, focusLine: Int?, highlight: Range<Int>? = nil)
    /// The file's declarations.
    case outline(path: String)

    /// The path either shape is about, which is also the cache key.
    public var path: String {
        switch self {
        case .text(let path, _, _): path
        case .outline(let path): path
        }
    }

    /// Derive from a row and the style its picker asked for.
    ///
    /// The parsing is `PickerTarget`'s, deliberately: rows already encode what they refer to
    /// and a second parser here would be a second thing to keep in step. Anything that is not
    /// a file — a command, a menu path, an editor tab addressed by coordinates — has nothing
    /// to preview and says so by returning nil.
    public static func of(_ item: PickerItem, style: PreviewStyle) -> PreviewRequest? {
        guard style != .none else { return nil }
        guard case .file(let path, let line) = PickerTarget.parse(item.id) else { return nil }
        return switch style {
        case .text: .text(path: path, focusLine: line, highlight: nil)
        case .outline: .outline(path: path)
        case .none: nil
        }
    }
}

// MARK: - the arithmetic

/// Which slice of a file to show.
///
/// Every index here is **1-based**, because that is what a grep hit and a symbol both hand you,
/// and converting at the edges is how off-by-ones get in. This is four clamps and it is the
/// only part of the feature that can be wrong without looking wrong, which is why it is the
/// part with the tests.
public struct PreviewWindow: Hashable, Sendable {
    /// The file line that the first shown line is. 1 when there is nothing to show.
    public let firstLine: Int
    public let count: Int

    public init(firstLine: Int, count: Int) {
        self.firstLine = firstLine
        self.count = count
    }

    /// The last file line shown, or `nil` when the window is empty.
    public var lastLine: Int? { count > 0 ? firstLine + count - 1 : nil }

    /// Centre `line` in a window of `capacity`, clamped to a file of `total` lines.
    ///
    /// Two rules that are not obvious from "centre it". Near the **top**, the window does not
    /// scroll above line 1 to keep the focus centred — it stops, and the focus sits high, which
    /// is what every editor does. Near the **bottom**, the window still shows `capacity` lines
    /// rather than running off the end half-empty, so the pane never changes height.
    ///
    /// The focus is placed slightly **above** centre on purpose: a declaration's useful context
    /// is the doc comment above it at least as often as the body below it.
    public static func around(line: Int?, total: Int, capacity: Int) -> PreviewWindow {
        guard total > 0, capacity > 0 else { return PreviewWindow(firstLine: 1, count: 0) }
        let shown = min(capacity, total)
        guard let line else { return PreviewWindow(firstLine: 1, count: shown) }

        let clamped = min(max(line, 1), total)
        // Biased above centre: more lines below the focus than above it.
        let above = (shown - 1) / 3
        let first = min(max(clamped - above, 1), total - shown + 1)
        return PreviewWindow(firstLine: first, count: shown)
    }
}

// MARK: - what comes back

/// How sourcekitd's syntax kinds are reduced to the handful a pane actually paints.
///
/// Core names the *role*, never the colour — the same discipline as `IconTint`, and for the
/// same reason: the palette belongs in the app, where it can adapt to light and dark.
public enum SyntaxRole: String, Hashable, Sendable, CaseIterable {
    case keyword, string, number, comment, docComment, typeName, attribute, plain
}

/// One run of coloured text, as an offset into the *file*, not into the shown window.
public struct SyntaxToken: Hashable, Sendable {
    public let role: SyntaxRole
    public let offset: Int
    public let length: Int

    public init(role: SyntaxRole, offset: Int, length: Int) {
        self.role = role
        self.offset = offset
        self.length = length
    }
}

/// One coloured run inside a drawn line, as a **UTF-16 range** into that line's text.
///
/// Core does this conversion, not the view. sourcekitd reports UTF-8 byte offsets into the
/// whole file; `NSAttributedString` counts UTF-16 within one line; and tabs are expanded before
/// drawing, which moves every offset on an indented line. Three conversions that have to agree,
/// so they happen once, here, where they are tested — rather than in a `draw(_:)` that nobody
/// can put a breakpoint in usefully.
public struct PreviewSpan: Hashable, Sendable {
    public let role: SyntaxRole
    public let start: Int
    public let length: Int

    public init(role: SyntaxRole, start: Int, length: Int) {
        self.role = role
        self.start = start
        self.length = length
    }
}

/// One line as the pane draws it: already tab-expanded, with its colour runs resolved.
public struct PreviewLine: Hashable, Sendable {
    public let number: Int
    public let text: String
    public let spans: [PreviewSpan]
    /// The searched-for text, as a UTF-16 range into `text`. Set on the matched line only.
    public let highlight: Range<Int>?

    public init(number: Int, text: String, spans: [PreviewSpan] = [],
                highlight: Range<Int>? = nil) {
        self.number = number
        self.text = text
        self.spans = spans
        self.highlight = highlight
    }
}

/// Text in context: what a search hit or a symbol shows.
public struct TextPreview: Hashable, Sendable {
    public let lines: [PreviewLine]
    /// The file line to mark — not an index into `lines`.
    public let focusLine: Int?
    /// True when the file has more lines than the window shows, so the pane can say so
    /// instead of implying the file ends here.
    public let hasMore: Bool

    public var firstLine: Int { lines.first?.number ?? 1 }

    public init(lines: [PreviewLine], focusLine: Int?, hasMore: Bool = false) {
        self.lines = lines
        self.focusLine = focusLine
        self.hasMore = hasMore
    }
}

/// One declaration in a file's outline.
///
/// Nested, because a flat list of every method in a file is the thing the symbol picker
/// already is. The value here is shape: `KeymapSession` with its methods indented under it
/// reads as a table of contents.
public struct OutlineNode: Hashable, Sendable, Identifiable {
    public let name: String
    public let kind: SymbolKind
    public let line: Int
    /// `true` for `public` and `open`. The pane dims everything else, so the shape of a file's
    /// API is visible without reading the names.
    public let isPublic: Bool
    /// The first sentence of the declaration's documentation, when it has one.
    ///
    /// **This is the part no other picker has.** Treesitter gives Neovim a syntactic tree; it
    /// does not give it the compiler's view of a declaration with its documentation attached.
    public let summary: String?
    public let children: [OutlineNode]

    public var id: String { "\(line):\(name)" }

    public init(name: String, kind: SymbolKind, line: Int,
                isPublic: Bool = false, summary: String? = nil,
                children: [OutlineNode] = []) {
        self.name = name
        self.kind = kind
        self.line = line
        self.isPublic = isPublic
        self.summary = summary
        self.children = children
    }

    /// The badge the pane draws, which is the one the picker list already uses for symbols.
    public var icon: RowIcon { .symbol(kind) }

    /// Depth-first, with depth, which is the order and the indent the pane draws.
    public static func flatten(_ nodes: [OutlineNode], depth: Int = 0) -> [(node: OutlineNode, depth: Int)] {
        nodes.flatMap { [($0, depth)] + flatten($0.children, depth: depth + 1) }
    }

    /// The rows to draw when the outline is taller than the pane.
    ///
    /// **Breadth before depth, and this is the difference between the feature working and
    /// not.** A depth-first cut of a file with two enums at the top spends the whole pane on
    /// their cases and never reaches the type the file is named after — so the pane answers
    /// "is this the right file?" with everything except the answer. Filling by depth shows
    /// every top-level declaration first, then nests only into whatever room is left.
    ///
    /// The survivors come back in document order, because the pane is a table of contents and
    /// a table of contents is in the order of the thing it describes.
    public static func fitting(_ nodes: [OutlineNode],
                               capacity: Int) -> [(node: OutlineNode, depth: Int)] {
        let flat = flatten(nodes)
        guard capacity > 0 else { return [] }
        guard flat.count > capacity else { return flat }

        // Indices chosen shallowest-first; document order breaks ties because `enumerated`
        // preserves it and the sort below is stable on the index.
        let chosen = flat.enumerated()
            .sorted { ($0.element.depth, $0.offset) < ($1.element.depth, $1.offset) }
            .prefix(capacity)
            .map(\.offset)
        let keep = Set(chosen)
        return flat.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }
}

/// Text or outline. An enum rather than one struct with unused fields, because the two shapes
/// share nothing but the file they came from, and a single type would have meant discovering
/// that three stages into the drawing code.
public enum PreviewBody: Hashable, Sendable {
    case text(TextPreview)
    case outline([OutlineNode])
}

/// Why there is nothing to draw.
///
/// A *reason*, never an empty result: "this is a binary file" and "this is still loading" look
/// identical as an empty pane, and exactly one of them is a bug. The pane keeps its frame and
/// says which.
public enum PreviewUnavailable: Hashable, Sendable, Error {
    case loading
    case tooLarge(bytes: Int)
    case binary
    case unreadable
    case noOutline
    /// The row named a file name rather than a path, and more than one file answers to it.
    case ambiguous(candidates: Int)

    public var message: String {
        switch self {
        case .loading: "…"
        case .tooLarge(let bytes): "too large to preview (\(bytes / 1_000_000) MB)"
        case .binary: "binary file"
        case .unreadable: "could not be read as text"
        case .noOutline: "no declarations"
        case .ambiguous(let n): "\(n) files have this name"
        }
    }
}

/// What the loader hands the view: one or the other, always something to draw.
public typealias PreviewResult = Result<PreviewBody, PreviewUnavailable>

// MARK: - assembling what the pane draws

/// Turning a parsed file into the window the pane shows.
///
/// Pure, so the slicing and the three offset conversions are tested rather than eyeballed
/// through a panel that ignores the mouse and vanishes on Escape.
public enum PreviewBuilder {

    /// A tab drawn as a tab lands on `NSAttributedString`'s default stops, which do not line
    /// up with a monospaced gutter, so indented Swift comes out ragged. Expanding first means
    /// the spans are computed against the text that is actually drawn.
    public static let tabWidth = 4

    /// Everything a parsed file offers the pane, so the decision of *what* to show is made
    /// once and cannot differ between the running app and the tool used to look at it.
    public struct Source: Sendable {
        public let lines: LineTable
        public let bytes: [UInt8]
        public let tokens: [SyntaxToken]
        public let outline: [OutlineNode]
        /// Whether this file is one sourcekitd can parse at all. A Markdown file has no
        /// declarations because it cannot have any, which is a different answer from a Swift
        /// file that happens to declare nothing.
        public let isSource: Bool

        public init(lines: LineTable, bytes: [UInt8], tokens: [SyntaxToken],
                    outline: [OutlineNode], isSource: Bool) {
            self.lines = lines
            self.bytes = bytes
            self.tokens = tokens
            self.outline = outline
            self.isSource = isSource
        }
    }

    /// What the pane shows for a request against a parsed file.
    public static func body(for request: PreviewRequest, from source: Source,
                            capacity: Int) -> PreviewResult {
        switch request {
        case .text(_, let focusLine, let highlight):
            return .success(.text(text(lines: source.lines, bytes: source.bytes,
                                       tokens: source.tokens, focusLine: focusLine,
                                       capacity: capacity, highlight: highlight)))
        case .outline:
            guard source.outline.isEmpty else { return .success(.outline(source.outline)) }
            // A README or a JSON has no declarations and never will. Telling the user that is
            // useless; its opening lines are not, and they answer the same question the
            // outline was asked — what is this file?
            guard source.isSource else {
                return .success(.text(text(lines: source.lines, bytes: source.bytes,
                                           tokens: source.tokens, focusLine: nil,
                                           capacity: capacity)))
            }
            return .failure(.noOutline)
        }
    }

    /// - Parameter capacity: how many lines the pane has room for.
    public static func text(lines: LineTable, bytes: [UInt8], tokens: [SyntaxToken],
                            focusLine: Int?, capacity: Int,
                            highlight: Range<Int>? = nil) -> TextPreview {
        let window = PreviewWindow.around(line: focusLine,
                                          total: lines.lineCount,
                                          capacity: capacity)
        guard let last = window.lastLine else {
            return TextPreview(lines: [], focusLine: nil)
        }

        // Tokens grouped by the line they start on, so each line is built in one pass rather
        // than by walking every token in the file once per line.
        var byLine: [Int: [SyntaxToken]] = [:]
        for token in tokens {
            let line = lines.line(atByteOffset: token.offset)
            guard line >= window.firstLine, line <= last else { continue }
            byLine[line, default: []].append(token)
        }

        var drawn: [PreviewLine] = []
        drawn.reserveCapacity(window.count)
        for number in window.firstLine...last {
            guard let range = lines.byteRange(ofLine: number, in: bytes) else { continue }
            let raw = Array(bytes[range])
            // The highlight is a range within the matched line, so it applies to that line
            // and no other — a second line that happens to contain the word is not the hit.
            let (text, spans, mark) = expand(raw,
                                             lineStart: range.lowerBound,
                                             tokens: byLine[number] ?? [],
                                             highlight: number == focusLine ? highlight : nil)
            drawn.append(PreviewLine(number: number, text: text, spans: spans, highlight: mark))
        }

        return TextPreview(lines: drawn,
                           focusLine: focusLine.map { min(max($0, 1), lines.lineCount) },
                           hasMore: lines.lineCount > window.count)
    }

    /// Expand tabs and resolve each token to a UTF-16 range in the expanded text.
    ///
    /// Done together because they cannot be done apart: expanding a tab to four spaces moves
    /// everything after it, so a span computed before expansion points at the wrong glyph and
    /// a span computed after expansion has no byte offset to start from.
    private static func expand(_ raw: [UInt8], lineStart: Int, tokens: [SyntaxToken],
                               highlight: Range<Int>?) -> (String, [PreviewSpan], Range<Int>?) {
        // UTF-16 length of the expanded text at each byte offset in the raw line.
        var utf16AtByte = [Int](repeating: 0, count: raw.count + 1)
        var out = ""
        var utf16Count = 0
        var byte = 0
        while byte < raw.count {
            utf16AtByte[byte] = utf16Count
            if raw[byte] == 0x09 {
                let spaces = tabWidth - (utf16Count % tabWidth)
                out += String(repeating: " ", count: spaces)
                utf16Count += spaces
                byte += 1
                continue
            }
            // Copy one whole UTF-8 scalar, so a multi-byte character is never split.
            let width = utf8Width(raw[byte])
            let end = min(byte + width, raw.count)
            let piece = String(decoding: raw[byte..<end], as: UTF8.self)
            out += piece
            // Every byte of the scalar maps to the scalar's own start, so a token offset that
            // lands inside a character still resolves to a drawable position.
            for inner in byte..<end { utf16AtByte[inner] = utf16Count }
            utf16Count += piece.utf16.count
            byte = end
        }
        utf16AtByte[raw.count] = utf16Count

        let spans: [PreviewSpan] = tokens.compactMap { token in
            guard token.role != .plain else { return nil }
            let start = token.offset - lineStart
            guard start >= 0, start < raw.count else { return nil }
            let end = min(start + token.length, raw.count)
            guard end > start else { return nil }
            let from = utf16AtByte[start]
            let to = utf16AtByte[end]
            guard to > from else { return nil }
            return PreviewSpan(role: token.role, start: from, length: to - from)
        }
        // The match range is in bytes within the line, so it goes through the same map the
        // tokens do — a tab before the hit would otherwise put the mark in the wrong place.
        var mark: Range<Int>?
        if let highlight,
           highlight.lowerBound >= 0, highlight.upperBound <= raw.count,
           highlight.lowerBound < highlight.upperBound {
            let from = utf16AtByte[highlight.lowerBound]
            let to = utf16AtByte[highlight.upperBound]
            if to > from { mark = from..<to }
        }
        return (out, spans, mark)
    }

    private static func utf8Width(_ byte: UInt8) -> Int {
        switch byte {
        case 0x00...0x7F: 1
        case 0xC0...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF7: 4
        default: 1
        }
    }
}
