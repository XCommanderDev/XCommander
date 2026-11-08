import Foundation
import XCommanderCore

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
    /// Commands bound in the user's keymap — shipped or from their config — that resolved on
    /// the old Xcode and do not on the new one. The part that costs the user a key.
    public var lostBindings: [(command: String, title: String, identifier: String)]
    /// The leader, as the user sees it, and any Xcode items the new build put on that chord.
    ///
    /// A leader is swallowed while Xcode is in front, so an item Apple moves onto it becomes
    /// unreachable — not broken in this app, but silently taken from Xcode, which is worse:
    /// nobody would think to blame the companion.
    public var leader: String
    public var newlyShadowed: [MenuEntry]

    public init(from: XcodeRelease, to: XcodeRelease, diff: CatalogueDiff,
                lostBindings: [(command: String, title: String, identifier: String)],
                leader: String = "the leader", newlyShadowed: [MenuEntry] = []) {
        self.from = from
        self.to = to
        self.diff = diff
        self.lostBindings = lostBindings
        self.leader = leader
        self.newlyShadowed = newlyShadowed
    }

    /// True when there is anything worth writing down. Apple adding forty commands we do not
    /// bind is not; a changed title or a command no longer seen is, quietly, in the file.
    public var isWorthTelling: Bool {
        needsAttention || !diff.retitled.isEmpty || !diff.removed.isEmpty
    }

    /// True only when the upgrade cost the user something: a key of theirs, or one of Xcode's
    /// own shortcuts now behind their leader. Only this earns the line in the menu bar.
    ///
    /// Everything else in a diff depends partly on what was on screen when each build was
    /// read — measured on the 27.0 to 27.2 upgrade, most "renames" were the open file's name
    /// and most "removals" were selection-dependent `File > New` items. Interrupting someone
    /// with that is noise, and noise trains people to ignore the one line that matters.
    public var needsAttention: Bool { !lostBindings.isEmpty || !newlyShadowed.isEmpty }

    public static var url: URL {
        SnapshotStore.directory.appending(path: "CHANGES.md")
    }

    public func write(to url: URL = ChangeReport.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try markdown.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// One line for the menu bar, naming the most costly thing that happened.
    public var summaryLine: String {
        if !lostBindings.isEmpty {
            let s = lostBindings.count == 1 ? "" : "s"
            return "Xcode \(to.version) removed \(lostBindings.count) command\(s) you had bound."
        }
        if let first = newlyShadowed.first {
            return "Xcode \(to.version) put \(first.title) on \(leader), your leader key."
        }
        if !diff.retitled.isEmpty {
            let s = diff.retitled.count == 1 ? "" : "s"
            return "Xcode \(to.version) changed \(diff.retitled.count) menu title\(s). Nothing you bound was lost."
        }
        let s = diff.removed.count == 1 ? "" : "s"
        return "Xcode \(to.version) removed \(diff.removed.count) command\(s). Nothing you bound was lost."
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
            another use, bind it in `~/.config/xcommander/config.toml`.

            """
            for lost in lostBindings {
                out += "- `\(lost.command)` — \(lost.title) (was `\(lost.identifier)`)\n"
            }
        }

        if !newlyShadowed.isEmpty {
            out += """

            ## Xcode commands your leader key now hides

            \(leader) is your leader, so XCommander takes it before Xcode sees it. This Xcode
            put these commands on the same keys, which makes them unreachable from the keyboard
            while XCommander runs. Pick a different leader in Settings if you need them.

            """
            for entry in newlyShadowed {
                out += "- \(entry.path.joined(separator: " > "))\n"
            }
        }

        if !diff.retitled.isEmpty {
            out += """

            ## Menu titles that changed

            These still work. XCommander finds them by the action behind the menu item, not
            by its title, so a new title costs nothing. Some are Apple's renames; others
            follow what was on screen, like a toggle showing its other state, so treat this
            list as a hint.


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

        // The bound ones are already listed above, under the heading that says what to do.
        let lost = Set(lostBindings.map(\.identifier))
        let unbound = diff.removed.filter { !lost.contains($0.identifier) }
        if !unbound.isEmpty {
            out += """

            ## Commands no longer seen (that you had not bound)

            XCommander has only seen this Xcode in the situations you have used it in, and
            some commands appear only when something is selected or running. A command here
            may come back.

            """
            for entry in unbound.prefix(40) {
                out += "- \(entry.path.joined(separator: " > "))\n"
            }
            if unbound.count > 40 { out += "- …and \(unbound.count - 40) more\n" }
        }

        if !diff.added.isEmpty {
            out += """

            ## Commands seen for the first time

            Some are new in this Xcode; others only appear in situations the old one was
            never seen in. All are already searchable in the command palette. Binding one to
            a key is a decision for you: the which-key panel is curated on purpose.


            """
            for entry in diff.added.prefix(40) {
                out += "- \(entry.path.joined(separator: " > "))\n"
            }
            if diff.added.count > 40 { out += "- …and \(diff.added.count - 40) more\n" }
        }

        return out
    }

    // MARK: - the window, which no snapshot covers

    /// What to add to the report when a command that needs Xcode's window failed and the
    /// window no longer looks the way this app expects.
    ///
    /// Appended rather than written fresh, because it may arrive days after the menu report
    /// for the same build, and the two belong in the same place: both are "this Xcode is not
    /// the one XCommander was measured against".
    public static func windowNote(release: XcodeRelease, failed: [XcodeAXSchema.Finding]) -> String {
        var out = """

        ## Xcode \(release.version) (\(release.build)): the window looks different

        A command that works inside Xcode's window could not find what it looks for. If a
        project window with a source editor was open at the time, this Xcode has probably
        changed its window, and the commands below will not work until XCommander is
        updated. Run `xcmdr doctor` for the details, and please report it.

        """
        for finding in failed {
            out += "- \(finding.assumption): \(finding.detail)\n"
        }
        return out
    }

    public static func appendWindowNote(_ note: String, to url: URL = ChangeReport.url) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try (existing + note).data(using: .utf8)!.write(to: url, options: .atomic)
    }
}
