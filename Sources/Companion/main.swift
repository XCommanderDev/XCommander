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
//   Autographe --preview <file> [n] what the preview pane would draw, as text
//   Autographe --preview-image …     the same, rendered as a PNG to look at
if let mode = CommandLine.arguments.dropFirst().first,
   mode == "--check" || mode == "--print-reference" {
    let files = Array(CommandLine.arguments.dropFirst(2))
    exit(ConfigCommandLine.run(mode: mode, files: files) ? 0 : 1)
}
if CommandLine.arguments.dropFirst().first == "--preview-image" {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard arguments.count >= 2 else {
        FileHandle.standardError.write(Data("usage: --preview-image <file> <out.png> [line] [--dark]\n".utf8))
        exit(1)
    }
    let line = arguments.dropFirst(2).first.flatMap(Int.init)
    exit(PreviewImageCommandLine.run(path: arguments[0], output: arguments[1], line: line,
                                     dark: arguments.contains("--dark")) ? 0 : 1)
}
if CommandLine.arguments.dropFirst().first == "--preview" {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard let path = arguments.first else {
        FileHandle.standardError.write(Data("usage: --preview <file> [line]\n".utf8))
        exit(1)
    }
    exit(PreviewCommandLine.run(path: path, line: arguments.dropFirst().first.flatMap(Int.init)) ? 0 : 1)
}

// A menu-bar app: no Dock icon, no main menu, no window until the overlay wants one.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
