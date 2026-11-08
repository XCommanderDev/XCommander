import Foundation

/// Which tier a capability belongs to.
public enum Tier: String, Hashable, Sendable, Codable, CaseIterable {
    case free, pro
}

/// One section a configuration file may contain, and what it costs.
public struct Capability: Hashable, Sendable {
    /// The top-level table name: `keys`, `groups`, `commands`, `layouts`.
    public var section: String
    public var tier: Tier
    /// Whether *this build* can act on it. A section can be known to the format and not yet
    /// implemented — that is a normal state for a versioned format, and it must produce an
    /// honest message rather than silence.
    public var isImplemented: Bool
    /// One line, used verbatim in diagnostics and in the generated reference.
    public var summary: String
}

/// **The public contract.** Everything a configuration file is allowed to say, in one table.
///
/// This is the answer to "do I need to publish a package for people to write configs
/// against?" — no, because nobody compiles anything against this. What third parties need is
/// a *vocabulary* and a promise about it: the section names below, the command ids in
/// `CommandRegistry`, and the key syntax in `KeySequence`. All three are data this app can
/// print, which is why `tools/print-config-reference.sh` generates the reference rather than
/// anyone maintaining one by hand. A hand-written document is a fourth thing to keep in step,
/// and it is always the one that is wrong.
///
/// **Adding a capability is adding a row here**, plus a decoder for its shape and a consumer
/// for its result. The gating, the diagnostics and the reference all follow from the row.
public enum ConfigSchema {

    /// Bumped when a change would make an old file mean something different. A file states
    /// the version it was written against, and this app refuses one it does not understand
    /// rather than guessing — the moment somebody publishes a config, its shape is a promise.
    public static let version = 1

    public static let capabilities: [Capability] = [
        Capability(section: "general", tier: .free, isImplemented: true,
                   summary: "leader key, panel delay, sequence timeout"),
        Capability(section: "groups", tier: .free, isImplemented: true,
                   summary: "what the which-key panel calls each prefix"),
        Capability(section: "keys", tier: .free, isImplemented: true,
                   summary: "bind a key sequence to a command id"),
        Capability(section: "unbind", tier: .free, isImplemented: true,
                   summary: "remove a binding the app ships"),
        Capability(section: "commands", tier: .pro, isImplemented: false,
                   summary: "macros: a named sequence of command ids"),
        Capability(section: "layouts", tier: .pro, isImplemented: false,
                   summary: "saved pane arrangements"),
    ]

    public static func capability(section: String) -> Capability? {
        capabilities.first { $0.section == section }
    }

    /// For the "unknown section" diagnostic, which should say what the known ones are.
    public static var sectionNames: [String] { capabilities.map(\.section) }
}
