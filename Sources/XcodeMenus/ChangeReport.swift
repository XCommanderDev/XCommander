import Foundation
import AutographeCore

/// What to tell the user after Xcode changed under them.
///
/// **The report is a file, not a dialog.** This app is for people who keep their editor
/// config in git; a Markdown file beside their `config.toml` is something they can read when
/// they choose, diff against last time, and delete. A modal sheet on launch would interrupt
/// exactly the work the app exists to speed up. The app's only interruption is one line in
/// the menu bar saying the file is there.
public struct ChangeReport {

    public var from: XcodeRelease
    public var to: XcodeRelease
    public var diff: CatalogueDiff
    /// Bindings the app ships that no longer resolve — the part that costs the user a key.
    public var lostBindings: [(command: String, title: String, identifier: String)]

    public init(from: XcodeRelease, to: XcodeRelease, diff: CatalogueDiff,
                lostBindings: [(command: String, title: String, identifier: String)]) {
        self.from = from
        self.to = to
        self.diff = diff
        self.lostBindings = lostBindings
    }

    /// True when there is anything a user would care about. Apple adding forty commands we
    /// do not bind is not news; losing one of their keys is.
    public var isWorthTelling: Bool { !lostBindings.isEmpty || !diff.retitled.isEmpty || !diff.removed.isEmpty }

    public static var url: URL {
        SnapshotStore.directory.appending(path: "CHANGES.md")
    }

    public func write(to url: URL = ChangeReport.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try markdown.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    public var summaryLine: String {
        if !lostBindings.isEmpty {
            let s = lostBindings.count == 1 ? "" : "s"
            return "Xcode \(to.version) removed \(lostBindings.count) command\(s) you had bound."
        }
        return "Xcode \(to.version) renamed \(diff.retitled.count) commands. Nothing you bound was lost."
    }

    public var markdown: String {
        var out = """
        # Xcode \(from.version) (\(from.build)) → \(to.version) (\(to.build))

        \(summaryLine)

        This file is written by XCommander when it first sees a new Xcode build. It is safe
        to delete; it will be written again the next time Xcode changes.

        """

        if !lostBindings.isEmpty {
            out += """

            ## Keys that no longer do anything

            Xcode no longer offers these commands, so XCommander hides them from the
            which-key panel rather than leaving a key that silently fails. To put the key to
            another use, bind it in `~/.config/autographe/config.toml`.

            """
            for lost in lostBindings {
                out += "- `\(lost.command)` — \(lost.title) (was `\(lost.identifier)`)\n"
            }
        }

        if !diff.retitled.isEmpty {
            out += """

            ## Commands Apple renamed

            These still work. XCommander finds them by the action behind the menu item, not
            by its title, so a rename costs nothing — they are listed only so the new names
            are not a surprise.

            """
            for change in diff.retitled {
                out += "- \(change.before) → **\(change.after)**\n"
            }
        }

        if !diff.moved.isEmpty {
            out += "\n## Commands Apple moved\n\n"
            for change in diff.moved {
                out += "- \(change.identifier): \(change.before) → **\(change.after)**\n"
            }
        }

        if diff.shortcutsCompared, !diff.rebound.isEmpty {
            out += "\n## Shortcuts Apple changed\n\n"
            for change in diff.rebound {
                out += "- \(change.identifier): \(change.before) → **\(change.after)**\n"
            }
        } else if !diff.shortcutsCompared {
            out += """

            ## Shortcuts

            Not compared: the two snapshots were taken under different keyboard layouts, and
            Xcode reports a shortcut as the character it produces. Nothing is wrong.

            """
        }

        if !diff.removed.isEmpty {
            out += "\n## Commands Apple removed (that you had not bound)\n\n"
            for entry in diff.removed.prefix(40) {
                out += "- \(entry.path.joined(separator: " > "))\n"
            }
            if diff.removed.count > 40 { out += "- …and \(diff.removed.count - 40) more\n" }
        }

        if !diff.added.isEmpty {
            out += """

            ## Commands Apple added

            All of these are already searchable in the command palette. Binding one to a key
            is a decision for you: the which-key panel is curated on purpose.

            """
            for entry in diff.added.prefix(40) {
                out += "- \(entry.path.joined(separator: " > "))\n"
            }
            if diff.added.count > 40 { out += "- …and \(diff.added.count - 40) more\n" }
        }

        return out
    }
}
