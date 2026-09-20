import Foundation
import AutographeCore

/// Where what we know about each Xcode is kept, and how it accumulates.
///
/// Beside the user's config, in `~/.config/autographe/xcode/`, as plain sorted JSON. That is
/// deliberate: this audience reads their dotfiles, and a file they can `cat`, `git diff` and
/// delete is a better answer than a database they cannot see. Deleting one costs nothing —
/// the app rebuilds it by looking at Xcode again.
public struct SnapshotStore {

    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".config/autographe/xcode", directoryHint: .isDirectory)
    }

    public var directory: URL
    public init(directory: URL = SnapshotStore.directory) { self.directory = directory }

    public func url(forBuild build: String) -> URL {
        directory.appending(path: "\(sanitise(build)).json")
    }

    /// Build identifiers come from Xcode's own bundle, but they land in a filename, so they
    /// are not taken on trust.
    private func sanitise(_ build: String) -> String {
        let allowed = build.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return allowed.isEmpty ? "unknown" : String(allowed.prefix(64))
    }

    public func load(build: String) -> MenuSnapshot? {
        guard let data = try? Data(contentsOf: url(forBuild: build)) else { return nil }
        return try? MenuSnapshot.decode(data)
    }

    public func save(_ snapshot: MenuSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snapshot.encoded().write(to: url(forBuild: snapshot.release.build), options: .atomic)
    }

    /// Fold a fresh scan into what is already known about that build and write it back.
    ///
    /// Returns the accumulated snapshot, which is the one worth asking questions of: a
    /// single scan is one context, and the union of many is the menu.
    @discardableResult
    public func record(_ scan: MenuSnapshot) throws -> MenuSnapshot {
        let merged = load(build: scan.release.build).map { $0.merging(scan) } ?? scan
        try save(merged)
        return merged
    }

    /// Every build we have ever recorded, newest capture first.
    public func knownBuilds() -> [(build: String, snapshot: MenuSnapshot)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (String, MenuSnapshot)? in
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? MenuSnapshot.decode(data) else { return nil }
                return (snapshot.release.build, snapshot)
            }
            .sorted { $0.1.capturedAt > $1.1.capturedAt }
            .map { (build: $0.0, snapshot: $0.1) }
    }

    /// The most recently seen build that is not this one — what an upgrade moved away from.
    public func previousBuild(before build: String) -> MenuSnapshot? {
        knownBuilds().first { $0.build != build }?.snapshot
    }
}
