import Foundation

/// A version number such as `1.2.0` or `0.1.0-alpha.3`, ordered the way semantic versioning
/// orders them: `0.1.0-alpha.2` < `0.1.0-alpha.10` < `0.1.0-beta.1` < `0.1.0` < `0.2.0`.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Major, minor, patch. A missing part counts as 0, so `1.2` equals `1.2.0`.
    public let numbers: [Int]
    /// The part after the hyphen, split on dots: `["alpha", "3"]`. Empty for a final release.
    public let prerelease: [String]

    /// Accepts a leading `v` (git tags are written `v1.2.0`) and ignores build metadata after a
    /// `+`. Returns nil for anything that isn't a version.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }

        let core: Substring
        if let hyphen = rest.firstIndex(of: "-") {
            core = rest[..<hyphen]
            prerelease = rest[rest.index(after: hyphen)...].split(separator: ".").map(String.init)
            if prerelease.isEmpty { return nil }
        } else {
            core = rest
            prerelease = []
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        numbers = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        numbers.map(String.init).joined(separator: ".")
            + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
        // Same numbers: a prerelease comes before the final release it leads to.
        switch (a.isPrerelease, b.isPrerelease) {
        case (false, false): return false
        case (true, false): return true
        case (false, true): return false
        case (true, true): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j         // numbers compare as numbers: 2 < 10
            case (_?, nil): return true             // a number comes before a word
            case (nil, _?): return false
            case (nil, nil): return x < y           // words compare alphabetically: alpha < beta
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// Which release, if any, to offer someone.
public enum UpdateCheck {

    /// The newest release worth offering to someone running `current`.
    ///
    /// Someone on a prerelease opted into testing, so they're offered newer prereleases as well
    /// as final releases. Someone on a final release is only offered final releases. Tags that
    /// aren't versions are ignored, and so is everything that isn't newer than `current`.
    public static func newest(in tags: [String], current: String) -> String? {
        guard let running = ReleaseVersion(current) else { return nil }
        let candidates = tags.compactMap { tag in ReleaseVersion(tag).map { (tag, $0) } }
            .filter { $0.1 > running && (running.isPrerelease || !$0.1.isPrerelease) }
        return candidates.max { $0.1 < $1.1 }?.0
    }
}
