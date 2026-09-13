import AutographeCore
import Foundation
import os

/// Reads and parses the file under the picker's cursor, without ever being on the keystroke path.
///
/// The picker redraws on every key, and the selection moves on every arrow. So the two things
/// this must never do are read a file synchronously and read forty files because a key was held
/// down. It debounces, it does the work on a background queue, and it drops anything that lands
/// after the selection has moved on.
///
/// **Cancellation is a counter, not a cancelled read.** Every request bumps a generation and a
/// completion whose generation is stale is discarded. Truly cancelling a 64 KB read buys nothing
/// and costs a lot of machinery.
///
/// **The cache is of the parse, not of the pane.** Arrowing through twenty search hits in one
/// file re-slices a parse we already have, which is why it feels instant: only the first hit in
/// each file costs anything.
@MainActor
final class PreviewLoader {

    /// Beyond this we do not read at all. A generated JSON in the file index can be tens of
    /// megabytes and the pane wants forty lines.
    ///
    /// **Matched to ripgrep's `--max-filesize`**, deliberately. With a lower cap here, a search
    /// can return hits in a file the preview then refuses to open — the list offers you a
    /// result and the pane tells you it will not show it, which reads as a bug because it is
    /// one. The two limits belong to the same decision, so they are the same number.
    nonisolated static let maxBytes = 2_000_000
    /// A NUL in the first few kilobytes means binary. Cheap, and right about every file the
    /// index actually offers — a compiled `.plist` and a `.strings` in UTF-16 both trip it.
    nonisolated private static let sniffBytes = 8_000
    nonisolated private static let debounceInterval: TimeInterval = 0.06

    nonisolated private struct Parsed {
        let bytes: [UInt8]
        let lines: LineTable
        let tokens: [SyntaxToken]
        let outline: [OutlineNode]
        /// Whether sourcekitd looked at this file at all. A Markdown file has no declarations
        /// because it cannot have any, which is a different answer from a Swift file that
        /// happens to declare nothing.
        let isSource: Bool
        let modified: Date?
    }

    private var cache: [String: Parsed] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 12

    private var generation = 0
    private var debounce: Timer?
    private let queue = DispatchQueue(label: "com.wassimans.AutographeForXcode.preview",
                                      qos: .userInitiated)
    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "preview")

    /// The project the picker is working in. Nothing outside it is ever read.
    ///
    /// **This is a privacy guard, not a tidiness one.** If the project sits under `~/Documents`,
    /// `~/Desktop` or `~/Downloads`, macOS asks for Files and Folders the first time we read
    /// inside it — and with a preview that prompt would fire on an *arrow key*, which is the
    /// worst moment in the app to stop and put up a dialog. Restricting reads to the root we
    /// already enumerated to build the file index means the grant is either already given or
    /// there are no rows to move through.
    var projectRoot: String?

    /// Ask for a preview. Safe to call on every selection change; most calls do no work.
    func request(_ request: PreviewRequest, capacity: Int, columns: Int,
                 completion: @escaping @MainActor (PreviewResult) -> Void) {
        generation += 1
        let generation = generation
        debounce?.invalidate()

        let path = request.path
        guard isInsideProject(path) else {
            completion(.failure(.unreadable))
            return
        }
        // Already parsed and still fresh: answer now. No debounce, no flicker, no queue hop —
        // this is the arrow-key case and it should feel like the list itself.
        if let parsed = cached(path) {
            completion(build(request, from: parsed, capacity: capacity, columns: columns))
            return
        }

        completion(.failure(.loading))
        let timer = Timer(timeInterval: Self.debounceInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.generation else { return }
                self.load(request, capacity: capacity, columns: columns,
                          generation: generation, completion: completion)
            }
        }
        debounce = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Drop everything in flight. Called when the picker closes, so a read that lands after
    /// the panel has gone does not redraw a dismissed view.
    func cancel() {
        generation += 1
        debounce?.invalidate()
        debounce = nil
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - the work

    private func load(_ request: PreviewRequest, capacity: Int, columns: Int, generation: Int,
                      completion: @escaping @MainActor (PreviewResult) -> Void) {
        let path = request.path
        queue.async { [weak self] in
            let outcome = Self.read(path: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.generation else { return }
                    switch outcome {
                    case .failure(let reason):
                        completion(.failure(reason))
                    case .success(let parsed):
                        self.store(parsed, for: path)
                        completion(self.build(request, from: parsed, capacity: capacity, columns: columns))
                    }
                }
            }
        }
    }

    /// Off the main thread. Everything that can refuse a file refuses it here, with a reason.
    nonisolated private static func read(path: String) -> Result<Parsed, PreviewUnavailable> {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxBytes { return .failure(.tooLarge(bytes: size)) }

        guard let data = fm.contents(atPath: path) else { return .failure(.unreadable) }
        let bytes = [UInt8](data)
        if bytes.prefix(sniffBytes).contains(0) { return .failure(.binary) }
        // Valid UTF-8 or nothing: a file that decodes to replacement characters everywhere is
        // not a preview, it is a wall of question marks.
        guard String(data: data, encoding: .utf8) != nil else { return .failure(.unreadable) }

        let lines = LineTable(bytes: bytes)
        var tokens: [SyntaxToken] = []
        var outline: [OutlineNode] = []
        // The gate lives in SourceKit, so the app and the render tool cannot disagree about
        // which files get parsed — and a Markdown file cannot come back with a class in it.
        if let parsed = SourceKit.shared.parse(path: path, lines: lines, bytes: bytes) {
            tokens = parsed.tokens
            outline = parsed.outline
        }
        return .success(Parsed(bytes: bytes, lines: lines, tokens: tokens, outline: outline,
                               isSource: SourceKit.canParse(path),
                               modified: attributes?[.modificationDate] as? Date))
    }

    private func build(_ request: PreviewRequest, from parsed: Parsed,
                       capacity: Int, columns: Int) -> PreviewResult {
        PreviewBuilder.body(for: request,
                            from: PreviewBuilder.Source(lines: parsed.lines,
                                                        bytes: parsed.bytes,
                                                        tokens: parsed.tokens,
                                                        outline: parsed.outline,
                                                        isSource: parsed.isSource),
                            capacity: capacity, columns: columns)
    }

    // MARK: - cache

    private func cached(_ path: String) -> Parsed? {
        guard let parsed = cache[path] else { return nil }
        // A file edited in Xcode since we parsed it must be read again, or the preview shows
        // yesterday's code with today's line numbers.
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard modified == parsed.modified else {
            cache[path] = nil
            cacheOrder.removeAll { $0 == path }
            return nil
        }
        return parsed
    }

    private func store(_ parsed: Parsed, for path: String) {
        if cache[path] == nil { cacheOrder.append(path) }
        cache[path] = parsed
        while cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache[oldest] = nil
        }
    }

    private func isInsideProject(_ path: String) -> Bool {
        guard let root = projectRoot else { return false }
        return ProjectPath.relative(of: path, under: root) != nil
    }
}
