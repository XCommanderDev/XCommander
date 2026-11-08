import Foundation

/// A file to read, named the way a user would say it.
public struct ConfigSource: Hashable, Sendable {
    /// `config.toml`, `.xcommander.toml` — what appears before the colon in a diagnostic.
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public struct ConfigBinding: Hashable, Sendable {
    public var sequence: [KeyEvent]
    public var commandID: String
    public var source: String
    public var line: Int
}

public struct ConfigGroup: Hashable, Sendable {
    public var sequence: [KeyEvent]
    public var title: String
    public var source: String
    public var line: Int
}

public struct ConfigUnbind: Hashable, Sendable {
    public var sequence: [KeyEvent]
    public var source: String
    public var line: Int
}

/// A section this build will not act on, and why. Carried rather than dropped, because the
/// user has to be told: a section that vanishes silently teaches people the app is broken.
public struct GatedSection: Hashable, Sendable {
    public var capability: Capability
    /// `layouts.debugging` — the full header, so the message points at what they wrote.
    public var name: String
    public var source: String
    public var line: Int
}

/// One configuration file, decoded but not yet applied.
///
/// The decoder's job stops at the boundary of what a single file can know. It checks syntax,
/// key sequences and the vetted leader — all of which are properties of the text. It does
/// **not** check command ids (that needs the registry), conflicts (that needs the other files
/// and the shipped keymap), or entitlement (that needs to know who is running). Those belong
/// to `ConfigResolver`, and keeping the split means a file can be decoded and shown in a
/// validator without an app around it.
public struct ConfigDocument: Sendable {
    public var source: String
    public var version: Int?
    public var leader: LeaderChoice?
    public var overlayDelay: Double?
    public var sequenceTimeout: Double?
    public var groups: [ConfigGroup] = []
    public var bindings: [ConfigBinding] = []
    public var unbinds: [ConfigUnbind] = []
    public var gated: [GatedSection] = []
}

public enum ConfigDecoder {

    /// Sensible bounds, enforced here rather than left to the app: a 5 ms panel delay makes
    /// the overlay a strobe, and a 300-second timeout means an armed sequence never expires.
    static let delayRange = 0.05...1.0
    static let timeoutRange = 3.0...120.0

    public static func decode(_ source: ConfigSource)
        -> (document: ConfigDocument, diagnostics: [ConfigDiagnostic]) {

        let (toml, parseDiagnostics) = TOML.parse(source.text, source: source.name)
        var diagnostics = parseDiagnostics
        var document = ConfigDocument(source: source.name)

        func error(_ line: Int, _ message: String) {
            diagnostics.append(ConfigDiagnostic(.error, source: source.name, line: line, message))
        }
        func warning(_ line: Int, _ message: String) {
            diagnostics.append(ConfigDiagnostic(.warning, source: source.name, line: line, message))
        }

        // MARK: version

        if let entry = toml.entry(at: ["version"]) {
            if case .integer(let v) = entry.value {
                document.version = v
                if v != ConfigSchema.version {
                    error(entry.line, "this file says version = \(v); this build understands "
                          + "version \(ConfigSchema.version)")
                }
            } else {
                error(entry.line, "version must be a number")
            }
        } else if !toml.entries.isEmpty || !toml.tables.isEmpty {
            error(1, "a configuration file must start with `version = \(ConfigSchema.version)`")
        }

        // MARK: [general]

        if let entry = toml.entry(at: ["general", "leader"]) {
            if let text = entry.value.stringValue {
                // The same vetted list the settings window offers. A file that could name any
                // key would walk straight around the guard the popup exists to provide.
                if let event = try? KeySequence.parseKey(text),
                   let choice = LeaderChoice.choice(for: event) {
                    document.leader = choice
                } else {
                    let options = LeaderChoice.allCases
                        .map { KeySequence.render([$0.event]) }
                        .joined(separator: ", ")
                    error(entry.line, "'\(text)' is not an available leader. Choose one of: \(options)")
                }
            } else {
                error(entry.line, "leader must be a string, like \"⌥RET\"")
            }
        }

        if let entry = toml.entry(at: ["general", "panel-delay"]) {
            if let ms = entry.value.numberValue {
                let seconds = ms / 1000
                if delayRange.contains(seconds) {
                    document.overlayDelay = seconds
                } else {
                    error(entry.line, "panel-delay must be between "
                          + "\(Int(delayRange.lowerBound * 1000)) and "
                          + "\(Int(delayRange.upperBound * 1000)) milliseconds")
                }
            } else {
                error(entry.line, "panel-delay must be a number of milliseconds")
            }
        }

        if let entry = toml.entry(at: ["general", "sequence-timeout"]) {
            if let seconds = entry.value.numberValue {
                if timeoutRange.contains(seconds) {
                    document.sequenceTimeout = seconds
                } else {
                    error(entry.line, "sequence-timeout must be between "
                          + "\(Int(timeoutRange.lowerBound)) and "
                          + "\(Int(timeoutRange.upperBound)) seconds")
                }
            } else {
                error(entry.line, "sequence-timeout must be a number of seconds")
            }
        }

        for entry in toml.children(of: ["general"])
        where !["leader", "panel-delay", "sequence-timeout"].contains(entry.path.last ?? "") {
            warning(entry.line, "[general] has no setting called '\(entry.path.last ?? "")'. Ignored.")
        }

        // MARK: [groups]

        for entry in toml.children(of: ["groups"]) {
            let written = entry.path.last ?? ""
            guard let title = entry.value.stringValue else {
                error(entry.line, "a group's value is the name the panel shows, as a string")
                continue
            }
            do {
                document.groups.append(ConfigGroup(sequence: try KeySequence.parse(written),
                                                   title: title,
                                                   source: source.name, line: entry.line))
            } catch let problem {
                error(entry.line, "\(problem)")
            }
        }

        // MARK: [keys]

        for entry in toml.children(of: ["keys"]) {
            let written = entry.path.last ?? ""
            guard let id = entry.value.stringValue else {
                error(entry.line, "a binding's value is a command id, as a string")
                continue
            }
            do {
                let sequence = try KeySequence.parse(written)
                // Chapter 7's rule, enforced where a file could break it: Esc is how a user
                // leaves a sequence, including one their own config has just broken.
                if sequence.first?.key == .special(.escape) {
                    error(entry.line, "ESC cannot be bound: it is how a sequence is cancelled")
                    continue
                }
                document.bindings.append(ConfigBinding(sequence: sequence, commandID: id,
                                                       source: source.name, line: entry.line))
            } catch let problem {
                error(entry.line, "\(problem)")
            }
        }

        // MARK: [unbind]

        if let entry = toml.entry(at: ["unbind", "keys"]) {
            guard let items = entry.value.arrayValue else {
                error(entry.line, "unbind.keys is a list of key sequences, like [\"g X\"]")
                return (document, diagnostics)
            }
            for item in items {
                guard let written = item.stringValue else {
                    error(entry.line, "every entry in unbind.keys is a string")
                    continue
                }
                do {
                    document.unbinds.append(ConfigUnbind(sequence: try KeySequence.parse(written),
                                                         source: source.name, line: entry.line))
                } catch let problem {
                    error(entry.line, "\(problem)")
                }
            }
        }

        // MARK: everything else

        // A table this build does not implement is not an error in the file — it is a fact
        // about this build, for the resolver to state. An unknown table *is* an error: it is
        // almost always a typo.
        var seen = Set<String>()
        for table in toml.tables {
            guard let head = table.path.first, !seen.contains(head) || table.path.count > 1
            else { continue }
            seen.insert(head)
            guard let capability = ConfigSchema.capability(section: head) else {
                error(table.line, "there is no section called [\(head)]. "
                      + "This format has: \(ConfigSchema.sectionNames.joined(separator: ", "))")
                continue
            }
            guard !capability.isImplemented else { continue }
            document.gated.append(GatedSection(capability: capability,
                                               name: table.path.joined(separator: "."),
                                               source: source.name, line: table.line))
        }

        return (document, diagnostics)
    }
}
