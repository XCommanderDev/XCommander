import AppKit
import AutographeCore

// Two command-line modes, handled before any UI exists.
//
// They are here rather than in a separate tool for one reason: **they must be the same code
// the app runs.** A validator that drifts from the loader is worse than no validator, because
// it certifies a file that will not work. Both modes go through `ConfigDecoder` and
// `ConfigResolver` exactly as a live reload does.
//
//   Autographe --check <file>...    validate configs, print diagnostics, exit non-zero on error
//   Autographe --print-reference    the whole contract: sections, key syntax, command ids
if let mode = CommandLine.arguments.dropFirst().first,
   mode == "--check" || mode == "--print-reference" {
    let files = Array(CommandLine.arguments.dropFirst(2))
    exit(ConfigCommandLine.run(mode: mode, files: files) ? 0 : 1)
}

// A menu-bar app: no Dock icon, no main menu, no window until the overlay wants one.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
