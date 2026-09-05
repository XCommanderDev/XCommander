import Foundation
import CompanionCore

/// The project's files, for the file picker.
///
/// We walk the filesystem ourselves rather than asking Xcode. That is not duplication for
/// its own sake: Open Quickly exists, but its ranking is Xcode's and we cannot reach it.
/// Owning the list means owning the ranking — fuzzy scoring over the path, and frecency,
/// which is what makes the second visit to a file a two-keystroke affair.
@MainActor
final class FileIndex {

    private(set) var items: [PickerItem] = []
    private var root: URL?
    private var lastScan: Date?
    /// How often a file has been chosen, and when. Survives only for the session; a file
    /// picker that forgets on relaunch is still better than one that never learns.
    private var frecency: [String: (count: Int, last: Date)] = [:]

    private static let skipped: Set<String> = [
        ".git", ".build", "build", "DerivedData", "Pods", "Carthage", "node_modules",
        ".swiftpm", "vendor", ".venv", "__pycache__", ".idea", "xcuserdata",
    ]
    private static let interesting: Set<String> = [
        "swift", "m", "mm", "h", "c", "cpp", "hpp", "metal", "plist", "entitlements",
        "json", "yml", "yaml", "toml", "md", "txt", "strings", "xcconfig", "sh", "rb", "py",
    ]
    private static let maxFiles = 20_000

    func invalidate() { lastScan = nil }

    /// Rescan when the project changed, or when the last scan is more than a minute old.
    func refreshIfNeeded(around document: URL?) {
        let newRoot = document.flatMap(Self.projectRoot(containing:))
        let stale = lastScan.map { Date().timeIntervalSince($0) > 60 } ?? true
        guard newRoot != root || stale else { return }
        root = newRoot
        lastScan = Date()
        items = newRoot.map(scan) ?? []
    }

    func note(_ path: String) {
        let existing = frecency[path]
        frecency[path] = (count: (existing?.count ?? 0) + 1, last: Date())
    }

    /// Walk up from the open document until something says "project": a `.xcodeproj`,
    /// a `Package.swift`, or a `.git`. The same shape as every editor's project detection.
    private static func projectRoot(containing document: URL) -> URL? {
        var directory = document.hasDirectoryPath ? document : document.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            let marks = contents.contains { name in
                name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
                    || name == "Package.swift" || name == ".git"
            }
            if marks { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    private func scan(_ root: URL) -> [PickerItem] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var found: [(url: URL, relative: String)] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"

        for case let url as URL in walker {
            if found.count >= Self.maxFiles { break }
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                // Prune whole trees rather than filtering their contents one file at a time.
                // A DerivedData directory can be larger than the project it belongs to.
                if Self.skipped.contains(name) || name.hasSuffix(".xcodeproj")
                    || name.hasSuffix(".xcworkspace") || name.hasSuffix(".xcassets") {
                    walker.skipDescendants()
                }
                continue
            }
            guard Self.interesting.contains(url.pathExtension) else { continue }
            found.append((url, String(url.path.dropFirst(prefix.count))))
        }

        return found
            .sorted { rank($0.url.path) > rank($1.url.path) }
            .map { file in
                PickerItem(id: "file:" + file.url.path,
                           title: file.relative,
                           detail: file.url.deletingLastPathComponent().lastPathComponent)
            }
    }

    /// Frecency: how often, decayed by how long ago.
    private func rank(_ path: String) -> Double {
        guard let hit = frecency[path] else { return 0 }
        let hours = max(1, Date().timeIntervalSince(hit.last) / 3600)
        return Double(hit.count) / hours
    }
}
