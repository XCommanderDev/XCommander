import Foundation

// xcdev: the day-to-day developer tool for XCommander.
//
//   swift run xcdev run       build the app, sign it and launch it
//   swift run xcdev stop      quit it
//   swift run xcdev logs      stream its logs
//   swift run xcdev bundle    build and sign the app without launching it
//   swift run xcdev build     just compile
//   swift run xcdev icons     regenerate the app icon and menu bar mark from Graphics/
//   swift run xcdev appcast <file>   write Sparkle's update feed from the GitHub releases
//
// Add --release to build an optimised app instead of a debug one.
//
// Why this exists: SwiftPM can compile the app but can't make a .app bundle, and macOS needs a
// signed bundle to grant Accessibility permission. Xcode does all of this for you; this tool
// does it from Terminal, which is faster when you're iterating.

let usage = """
    usage: swift run xcdev [run|stop|logs|bundle|build|icons|appcast <file>] [--release]

      run      build the app, sign it and launch it (the default)
      stop     quit the running app
      logs     stream the app's logs
      bundle   build and sign the app without launching it
      build    just compile
      icons    regenerate the app icon and menu bar mark from Graphics/
      appcast  write Sparkle's update feed to <file>, from the published GitHub releases
    """

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first { !$0.hasPrefix("-") } ?? "run"
let release = arguments.contains("--release")

do {
    let project = try Project.locate()
    let app = AppBuilder(project: project, configuration: release ? "release" : "debug")
    switch command {
    case "build": try app.build()
    case "bundle": try app.bundle()
    case "run":
        app.stop()
        try app.bundle()
        try app.launch()
    case "stop": app.stop()
    case "logs": try app.streamLogs()
    case "icons": try IconMaker(project: project).make()
    case "appcast":
        let rest = arguments.filter { !$0.hasPrefix("-") }.dropFirst()
        guard let path = rest.first else { throw Message("usage: swift run xcdev appcast <file>") }
        try Appcast().write(to: URL(fileURLWithPath: path))
    case "help", "--help", "-h":
        print(usage)
    default:
        print("Unknown command '\(command)'.\n\n\(usage)")
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
