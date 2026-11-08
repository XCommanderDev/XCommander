import Foundation
import CIndexStore
import XCommanderCore
import os

/// Xcode's symbol knowledge, read rather than recomputed.
///
/// Xcode maintains an index store per project under
/// `DerivedData/<project>/Index.noindex/DataStore` — the same data behind Open Quickly and
/// Jump to Definition. Reading it is the whole point: the editor does the heavy lifting and
/// we borrow the result, instead of running a second language server over the same code.
///
/// Everything here is defensive. The store may not exist yet, the library may be missing,
/// a record may fail to open, and none of that is allowed to be worse than "symbols
/// unavailable".
@MainActor
final class SymbolIndex {

    struct Result {
        var symbols: [ProjectSymbol]
        /// Set when there is nothing to show and the picker should say why.
        var unavailable: String?
    }

    private var cache: [String: [ProjectSymbol]] = [:]
    private var cacheStamp: [String: Date] = [:]
    private var loading = false

    private let log = Logger(subsystem: "dev.xcommander.XCommander", category: "index")

    var isAvailable: Bool { IndexStoreLibrary.shared.isAvailable }

    /// The index store for a project, via `DerivedData/*/info.plist`, whose `WorkspacePath`
    /// key names the project each folder belongs to. Matching by folder name would pick the
    /// wrong one whenever two projects share a name.
    static func storePath(forProjectAt root: URL) -> String? {
        let derived = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: derived, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }

        var best: (path: String, date: Date)?
        for entry in entries {
            let info = entry.appendingPathComponent("info.plist")
            guard let data = try? Data(contentsOf: info),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let workspace = plist["WorkspacePath"] as? String else { continue }
            // The workspace may be the project directory itself or a file inside it.
            guard workspace == root.path || workspace.hasPrefix(root.path + "/")
                    || root.path.hasPrefix(workspace + "/") else { continue }
            let store = entry.appendingPathComponent("Index.noindex/DataStore")
            guard FileManager.default.fileExists(atPath: store.path) else { continue }
            let date = (plist["LastAccessedDate"] as? Date) ?? .distantPast
            if best == nil || date > best!.date { best = (store.path, date) }
        }
        return best?.path
    }

    /// Load a project's symbols, off the main thread, and hand them back on it.
    ///
    /// A walk measured 82 ms on a small package, but a large project has far more units and
    /// this must never be on the keystroke path. Results are cached until the store changes.
    func symbols(forProjectAt root: URL, completion: @escaping @MainActor (Result) -> Void) {
        guard IndexStoreLibrary.shared.isAvailable else {
            completion(Result(symbols: [], unavailable: "Xcode's index library could not be loaded"))
            return
        }
        guard let store = Self.storePath(forProjectAt: root) else {
            completion(Result(symbols: [],
                              unavailable: "no index yet — open this project in Xcode and let it finish indexing"))
            return
        }

        let modified = (try? FileManager.default.attributesOfItem(atPath: store)[.modificationDate] as? Date) ?? nil
        if let cached = cache[store], cacheStamp[store] == modified {
            completion(Result(symbols: cached, unavailable: cached.isEmpty ? "no symbols indexed yet" : nil))
            return
        }
        guard !loading else { return }
        loading = true

        DispatchQueue.global(qos: .userInitiated).async {
            let raw = IndexStoreReader.readSymbols(atStorePath: store)
            let prepared = SymbolFilter.prepare(raw)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading = false
                    self.cache[store] = prepared
                    self.cacheStamp[store] = modified
                    self.log.notice("index: \(raw.count) raw, \(prepared.count) navigable symbols")
                    completion(Result(symbols: prepared,
                                      unavailable: prepared.isEmpty ? "no symbols indexed yet" : nil))
                }
            }
        }
    }

    func invalidate() {
        cache.removeAll()
        cacheStamp.removeAll()
    }
}

/// The walk itself. Free functions and a class for the C callbacks, because a C function
/// pointer cannot capture anything.
private final class Collector {
    var symbols: [ProjectSymbol] = []
    var currentFile = ""
    /// A hard ceiling. A very large workspace should degrade to "a lot of symbols" rather
    /// than to an unbounded allocation on a background thread.
    let limit = 200_000
    var stopped: Bool { symbols.count >= limit }
}

enum IndexStoreReader {

    /// Definitions and declarations. References are what "find usages" wants; a jump list
    /// full of them would be unusable.
    private static let wantedRoles: UInt64 = (1 << 0) | (1 << 1)

    nonisolated static func readSymbols(atStorePath path: String) -> [ProjectSymbol] {
        let library = IndexStoreLibrary.shared
        guard let create = library.storeCreate, let dispose = library.storeDispose,
              let unitsApply = library.unitsApply else { return [] }

        var error: indexstore_error_t?
        guard let store = create(path, &error) else { return [] }
        defer { dispose(store) }

        let collector = Collector()
        currentStore = store
        defer { currentStore = nil }

        let context = Unmanaged.passUnretained(collector).toOpaque()
        _ = unitsApply(store, 0, context, unitApplier)
        return collector.symbols
    }
}

/// The store being walked. A global because the C appliers below cannot capture, and the
/// walk is serialised by `SymbolIndex.loading`.
nonisolated(unsafe) private var currentStore: indexstore_t?

private let occurrenceApplier: indexstore_occurrence_applier_t = { context, occurrence in
    guard let context, let occurrence else { return true }
    let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
    if collector.stopped { return false }
    let library = IndexStoreLibrary.shared
    guard let roles = library.occurrenceRoles, let getSymbol = library.occurrenceSymbol,
          let lineCol = library.occurrenceLineCol, let kindOf = library.symbolKind,
          let nameOf = library.symbolName else { return false }
    guard roles(occurrence) & ((1 << 0) | (1 << 1)) != 0 else { return true }
    guard let symbol = getSymbol(occurrence) else { return true }
    let kind = SymbolKind(raw: kindOf(symbol))
    guard kind.isNavigable else { return true }          // cheap reject before building a String
    var line: UInt32 = 0, column: UInt32 = 0
    lineCol(occurrence, &line, &column)
    let name = IndexStoreLibrary.string(nameOf(symbol))
    guard !name.isEmpty else { return true }
    collector.symbols.append(ProjectSymbol(name: name, kind: kind,
                                           path: collector.currentFile, line: Int(line)))
    return true
}

private let dependencyApplier: indexstore_dependency_applier_t = { context, dependency in
    guard let context, let dependency, let store = currentStore else { return true }
    let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
    if collector.stopped { return false }
    let library = IndexStoreLibrary.shared
    guard let kindOf = library.dependencyKind, let nameOf = library.dependencyName,
          let pathOf = library.dependencyFilePath, let create = library.recordReaderCreate,
          let dispose = library.recordReaderDispose,
          let occurrences = library.recordOccurrencesApply else { return false }

    // Kind 2 is a record: one file's index data.
    guard kindOf(dependency) == 2 else { return true }
    let recordName = IndexStoreLibrary.string(nameOf(dependency))
    let filePath = IndexStoreLibrary.string(pathOf(dependency))
    guard !recordName.isEmpty, !filePath.isEmpty else { return true }
    // Skip the SDK and Xcode's own headers before opening the record at all: they are the
    // bulk of the store and none of it is the user's code.
    guard !SymbolFilter.isOutsideProject(filePath) else { return true }

    var error: indexstore_error_t?
    guard let record = create(store, recordName, &error) else { return true }
    defer { dispose(record) }
    collector.currentFile = filePath
    _ = occurrences(record, context, occurrenceApplier)
    return true
}

private let unitApplier: indexstore_unit_applier_t = { context, unitName in
    guard let context, let store = currentStore else { return true }
    let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
    if collector.stopped { return false }
    let library = IndexStoreLibrary.shared
    guard let create = library.unitReaderCreate, let dispose = library.unitReaderDispose,
          let deps = library.unitDepsApply else { return false }
    var error: indexstore_error_t?
    guard let unit = create(store, IndexStoreLibrary.string(unitName), &error) else { return true }
    defer { dispose(unit) }
    _ = deps(unit, context, dependencyApplier)
    return true
}
