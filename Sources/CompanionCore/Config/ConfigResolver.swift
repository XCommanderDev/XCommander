import Foundation

/// The shipped keymap as *data*, before it is built into a tree.
///
/// `DefaultKeymap.build()` goes straight from this table to a `Keymap`, which is right when
/// there is nothing to merge. A user's file has to be layered over it *before* insertion —
/// once bindings are in the trie, "replace the `m` group" is a surgical edit on a recursive
/// structure, and as a flat list it is a filter.
public struct KeymapBlueprint: Sendable {
    public var bindings: [(sequence: [KeyEvent], commandID: String)]
    public var groupTitles: [[KeyEvent]: String]

    public init(bindings: [(sequence: [KeyEvent], commandID: String)],
                groupTitles: [[KeyEvent]: String]) {
        self.bindings = bindings
        self.groupTitles = groupTitles
    }
}

/// What a set of configuration files resolved to.
public struct ConfigResolution: Sendable {
    /// **Non-nil only if the whole thing is usable.** There is no partial keymap: half a
    /// keymap is worse than an old one, because the failure is silent and intermittent.
    public var keymap: Keymap?
    public var leader: LeaderChoice
    public var overlayDelay: Double?
    public var sequenceTimeout: Double?
    public var diagnostics: [ConfigDiagnostic]

    public var isUsable: Bool { keymap != nil }

    /// The one line to put in the menu bar or the settings window. The reassurance is not
    /// decoration: a user who has just broken their config needs to know the app still works
    /// before they need to know why.
    public var summary: String? {
        guard let worst = diagnostics.forDisplay.first else { return nil }
        switch worst.severity {
        case .error:
            let n = diagnostics.errors.count
            return "\(worst)\n"
                + (n > 1 ? "…and \(n - 1) more. " : "")
                + "Using the last good configuration."
        case .warning, .notice:
            return worst.description
        }
    }
}

/// Files plus the shipped defaults, in, one keymap out.
///
/// The pipeline is three stages and each is a pure function: **parse** (text → entries with
/// positions), **decode** (entries → one document per file), **resolve** (documents + defaults
/// + registry + tier → a keymap). Nothing here touches the file system, a clock or a window,
/// which is why the whole feature is testable without an app around it — and why a `--check`
/// command that validates somebody's published config is the same code path as a live reload.
public enum ConfigResolver {

    public static func resolve(_ sources: [ConfigSource],
                               blueprint: KeymapBlueprint,
                               registry: CommandRegistry,
                               tier: Tier) -> ConfigResolution {

        var diagnostics: [ConfigDiagnostic] = []
        var documents: [ConfigDocument] = []
        for source in sources {
            let (document, problems) = ConfigDecoder.decode(source)
            documents.append(document)
            diagnostics.append(contentsOf: problems)
        }

        // MARK: entitlement
        //
        // Gating happens **here and nowhere else**, and it reads the same table for every
        // tier. There is no separate free-build code path to drift out of step, and a Pro
        // user's config still loads for a free user with its Pro sections announced — which
        // is what keeps a shared config shareable across the tier boundary.
        for document in documents {
            for gate in document.gated {
                let message: String
                if gate.capability.tier == .pro && tier == .free {
                    message = "[\(gate.name)] — \(gate.capability.summary) — "
                        + "requires Autographe Pro. Ignored."
                } else {
                    message = "[\(gate.name)] — \(gate.capability.summary) — "
                        + "is not implemented in this version. Ignored."
                }
                diagnostics.append(ConfigDiagnostic(.warning, source: gate.source,
                                                    line: gate.line, message))
            }
        }

        // MARK: merge
        //
        // Later files win, which is what makes a committed `.autographe.toml` one line long
        // instead of a copy of somebody's whole keymap.
        var bindings: [[KeyEvent]: ConfigBinding] = [:]
        for document in documents {
            for binding in document.bindings {
                if let existing = bindings[binding.sequence], existing.source != binding.source {
                    diagnostics.append(ConfigDiagnostic(
                        .notice, source: binding.source, line: binding.line,
                        "\(KeySequence.render(binding.sequence)) overrides "
                            + "\(existing.source):\(existing.line)"))
                } else if let existing = bindings[binding.sequence] {
                    diagnostics.append(ConfigDiagnostic(
                        .error, source: binding.source, line: binding.line,
                        "\(KeySequence.render(binding.sequence)) is bound twice in this file "
                            + "(also line \(existing.line))"))
                }
                bindings[binding.sequence] = binding
            }
        }

        // MARK: command ids
        //
        // A binding to an id nobody registered is an error, not a key that quietly does
        // nothing — and the registry knows every valid id, so it can say what was probably
        // meant. See `Suggestion` for why this is not the palette's fuzzy matcher.
        let ids = registry.all.map(\.id)
        for binding in bindings.values.sorted(by: { $0.line < $1.line }) {
            guard registry.command(id: binding.commandID) == nil else { continue }
            let suggestion = Suggestion.nearest(binding.commandID, in: ids)
            diagnostics.append(ConfigDiagnostic(
                .error, source: binding.source, line: binding.line,
                "there is no command called '\(binding.commandID)'"
                    + (suggestion.map { ". Did you mean '\($0)'?" } ?? "")))
        }

        // MARK: unbind

        var unbound: [[KeyEvent]] = []
        for document in documents {
            for unbind in document.unbinds {
                let hits = blueprint.bindings.filter { isPrefix(unbind.sequence, of: $0.sequence) }
                if hits.isEmpty {
                    diagnostics.append(ConfigDiagnostic(
                        .warning, source: unbind.source, line: unbind.line,
                        "nothing is bound at \(KeySequence.render(unbind.sequence)), "
                            + "so there is nothing to unbind"))
                }
                unbound.append(unbind.sequence)
            }
        }

        // MARK: build
        //
        // Config bindings go in first and the shipped ones fill in around them. A default
        // that collides with a user's binding is *dropped*, not reported as a conflict —
        // rebinding `m` to a command means replacing the whole `m` group, and that is the
        // feature, not an accident.
        var titles = blueprint.groupTitles
        for document in documents {
            for group in document.groups { titles[group.sequence] = group.title }
        }

        var keymap = Keymap()
        var failed = false
        for binding in bindings.values.sorted(by: { $0.sequence.count < $1.sequence.count }) {
            do {
                try keymap.bind(binding.sequence, to: binding.commandID, groupTitles: titles)
            } catch let problem as KeymapError {
                diagnostics.append(ConfigDiagnostic(.error, source: binding.source,
                                                    line: binding.line, "\(problem)"))
                failed = true
            } catch {
                failed = true
            }
        }

        for shipped in blueprint.bindings {
            if unbound.contains(where: { isPrefix($0, of: shipped.sequence) }) { continue }
            if let shadow = bindings.values.first(where: {
                isPrefix($0.sequence, of: shipped.sequence)
                    || isPrefix(shipped.sequence, of: $0.sequence)
            }) {
                diagnostics.append(ConfigDiagnostic(
                    .notice, source: shadow.source, line: shadow.line,
                    "replaces the shipped binding \(KeySequence.render(shipped.sequence)) "
                        + "(\(shipped.commandID))"))
                continue
            }
            // A shipped binding cannot fail against a keymap it was designed for, and the
            // config bindings that could have collided were filtered out above.
            try? keymap.bind(shipped.sequence, to: shipped.commandID, groupTitles: titles)
        }

        let usable = !failed && !diagnostics.hasErrors
        return ConfigResolution(
            keymap: usable ? keymap : nil,
            leader: documents.compactMap(\.leader).last ?? .default,
            overlayDelay: documents.compactMap(\.overlayDelay).last,
            sequenceTimeout: documents.compactMap(\.sequenceTimeout).last,
            diagnostics: diagnostics)
    }

    /// `["m"]` is a prefix of `["m", "m"]`, and of itself. Both directions matter: binding
    /// `m` replaces the `m` group, and binding `m m x` replaces `m m`.
    static func isPrefix(_ short: [KeyEvent], of long: [KeyEvent]) -> Bool {
        short.count <= long.count && Array(long.prefix(short.count)) == short
    }
}
