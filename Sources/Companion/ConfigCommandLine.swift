import AutographeCore
import Foundation

/// The two things a person publishing a configuration file needs from this app.
///
/// **This is the answer to "should the config format be an open-source package?".** Nobody
/// compiles anything against a dotfile, so there is nothing for a package to export. What a
/// config author actually needs is a *vocabulary* and a way to check their file against it —
/// so the app prints the vocabulary and validates the file, and both come from the same
/// tables the running app uses. A published reference that is generated cannot go stale, and
/// a validator that is the loader cannot disagree with it.
enum ConfigCommandLine {

    /// - Returns: whether the run succeeded, which is the process's exit status.
    static func run(mode: String, files: [String]) -> Bool {
        switch mode {
        case "--print-reference":
            printReference()
            return true
        case "--check":
            return check(files)
        default:
            return false
        }
    }

    // MARK: - the contract

    private static func printReference() {
        let (registry, keymap) = DefaultKeymap.build()

        print("# Autographe configuration reference")
        print("")
        print("Format version \(ConfigSchema.version). A file must begin with "
              + "`version = \(ConfigSchema.version)`.")
        print("Global file: ~/.config/autographe/config.toml")
        print("Per-project: .autographe.toml in the project root, layered over the global one.")
        print("")

        print("## Sections")
        print("")
        print("| section | tier | status | what it does |")
        print("|---|---|---|---|")
        for capability in ConfigSchema.capabilities {
            let status = capability.isImplemented ? "available" : "not yet implemented"
            print("| `[\(capability.section)]` | \(capability.tier.rawValue) "
                  + "| \(status) | \(capability.summary) |")
        }
        print("")

        print("## Key syntax")
        print("")
        print("A sequence is keys separated by spaces, written exactly as the which-key panel")
        print("shows them: `m m`, `c d`, `⌥RET`. Modifiers are ⌃ ⌥ ⇧ ⌘. Keys with no character")
        print("have names: \(SpecialKey.allCases.map(\.display).joined(separator: ", ")).")
        print("")
        print("Available leaders: "
              + LeaderChoice.allCases.map { "`\(KeySequence.render([$0.event]))`" }
                  .joined(separator: ", ") + ".")
        print("")

        print("## Commands")
        print("")
        print("\(registry.count) command ids, each usable as a value in `[keys]`.")
        print("")
        print("| id | what it does | shipped binding |")
        print("|---|---|---|")
        for command in registry.all {
            let binding = keymap.binding(for: command.id).map { KeySequence.render($0) } ?? ""
            print("| `\(command.id)` | \(command.title) | \(binding.isEmpty ? "—" : "`\(binding)`") |")
        }
    }

    // MARK: - the validator

    private static func check(_ files: [String]) -> Bool {
        guard !files.isEmpty else {
            print("usage: Autographe --check <file>…")
            return false
        }

        var sources: [ConfigSource] = []
        for path in files {
            let url = URL(fileURLWithPath: path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                print("cannot read \(path)")
                return false
            }
            sources.append(ConfigSource(name: url.lastPathComponent, text: text))
        }

        // Checked as a *free* build on purpose: it is the stricter of the two, so a config
        // that passes here loads for everybody, with Pro sections announced rather than
        // silently working for the author and mysteriously not for their readers.
        let registry = DefaultKeymap.build().registry
        let resolution = ConfigResolver.resolve(sources, blueprint: DefaultKeymap.blueprint,
                                                registry: registry, tier: .free)

        for problem in resolution.diagnostics.forDisplay {
            print("\(problem.severity.rawValue): \(problem)")
        }

        if resolution.isUsable {
            let n = resolution.diagnostics.filter { $0.severity == .warning }.count
            print("ok — \(files.count) file\(files.count == 1 ? "" : "s") loaded"
                  + (n > 0 ? ", \(n) warning\(n == 1 ? "" : "s")" : ""))
            return true
        }
        print("failed — \(resolution.diagnostics.errors.count) error(s); "
              + "this configuration would not be applied")
        return false
    }
}
