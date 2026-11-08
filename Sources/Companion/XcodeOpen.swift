import AppKit
import Foundation
import XCommanderCore
import os

/// Opening a file **in Xcode**, which is not the same thing as opening it.
///
/// `NSWorkspace.open(url)` hands the file to LaunchServices, which gives it to whatever app
/// owns the extension. For `.swift` that is Xcode and it looks like it works. For everything
/// else the file index offers — `md`, `json`, `yml`, `toml`, `sh`, `py`, `txt`, `plist` — it
/// is some other app entirely, or nothing, and the file the user asked for never appears in
/// the editor they asked from. That was the bug: picking `notes.md` launched a Markdown
/// previewer and left Xcode showing the file it was already showing.
///
/// `xed` is the developer tools' own "open in Xcode" command. It ignores the default handler,
/// takes an optional line, and brings Xcode forward.
enum XcodeOpen {
    private static let log = Logger(subsystem: "dev.xcommander.XCommander", category: "open")
    private static let xed = "/usr/bin/xed"

    static func file(at path: String, line: Int? = nil) {
        guard FileManager.default.isExecutableFile(atPath: xed) else {
            log.error("no xed at \(xed, privacy: .public); are the developer tools installed?")
            NSSound.beep()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xed)
        process.arguments = PickerTarget.xedArguments(path: path, line: line)
        do {
            try process.run()
            log.debug("opened \(path, privacy: .public) in Xcode")
        } catch {
            // The old code discarded this, so a failed open was indistinguishable from a
            // successful one that Xcode ignored.
            log.error("could not open \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }
}
