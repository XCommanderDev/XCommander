import Foundation

/// Something to tell the user about their configuration, with somewhere to point.
///
/// **The line number is the whole design.** A config error a user cannot locate is barely
/// better than no message at all, and a position is the one thing that is impossible to add
/// later without rewriting the parser — so every stage of the pipeline carries it, from the
/// scanner that read the byte to the resolver that rejected the binding.
///
/// Nothing here throws. A file with four mistakes should report four mistakes, not the first
/// one; a user fixing a config one error per save gives up around the third.
public struct ConfigDiagnostic: Hashable, Sendable, CustomStringConvertible {

    /// What a diagnostic does to the load, which is a property of the *diagnostic*, not of
    /// the caller's mood: an error means the resolution is unusable and the app keeps its
    /// last good configuration.
    public enum Severity: String, Hashable, Sendable, Comparable {
        /// The file cannot be applied.
        case error
        /// The file is applied; this part of it is not.
        case warning
        /// Applied, and worth saying — an override, a shadowed default.
        case notice

        private var rank: Int {
            switch self {
            case .error: 2
            case .warning: 1
            case .notice: 0
            }
        }

        public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    }

    public var severity: Severity
    /// The file's name as a user would say it — `config.toml`, `.xcommander.toml`.
    public var source: String
    public var line: Int
    public var message: String

    public init(_ severity: Severity, source: String, line: Int, _ message: String) {
        self.severity = severity
        self.source = source
        self.line = line
        self.message = message
    }

    /// The form the settings window and the log both use: `config.toml:14 — message`.
    public var description: String { "\(source):\(line) — \(message)" }
}

public extension Array where Element == ConfigDiagnostic {
    var errors: [ConfigDiagnostic] { filter { $0.severity == .error } }
    var hasErrors: Bool { contains { $0.severity == .error } }

    /// Worst first, then by position, so the line a user should look at is the first one
    /// they read.
    var forDisplay: [ConfigDiagnostic] {
        sorted { ($0.severity, $0.source, $0.line) > ($1.severity, $1.source, $1.line) }
    }
}
