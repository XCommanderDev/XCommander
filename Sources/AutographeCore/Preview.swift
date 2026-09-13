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
    case text(path: String, focusLine: Int?)
    /// The file's declarations.
    case outline(path: String)

    /// The path either shape is about, which is also the cache key.
    public var path: String {
        switch self {
        case .text(let path, _): path
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
        case .text: .text(path: path, focusLine: line)
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

/// Text in context: what a search hit or a symbol shows.
public struct TextPreview: Hashable, Sendable {
    public let lines: [String]
    /// The file line that `lines[0]` is.
    public let firstLine: Int
    /// The file line to mark — not an index into `lines`.
    public let focusLine: Int?
    /// Byte offsets are into the whole file, so a token is placed by finding its line.
    public let tokens: [SyntaxToken]
    /// True when the file has more lines than the window shows, so the pane can say so
    /// instead of implying the file ends here.
    public let hasMore: Bool

    public init(lines: [String], firstLine: Int, focusLine: Int?,
                tokens: [SyntaxToken] = [], hasMore: Bool = false) {
        self.lines = lines
        self.firstLine = firstLine
        self.focusLine = focusLine
        self.tokens = tokens
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
