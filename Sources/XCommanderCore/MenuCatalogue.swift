import Foundation

/// Xcode's menu bar, keyed by what survives an upgrade.
///
/// A command used to name a menu *path* — `["Editor", "Structure", "Toggle Comments"]` —
/// and Xcode 27 showed what that costs. Apple renamed four of the items this app binds,
/// moved none of them, and changed what none of them do; eight of 115 bound paths stopped
/// resolving, and the app would have silently lost the keys.
///
/// Every menu item also carries `AXIdentifier`, and for Xcode it is the Objective-C action
/// behind the item. On Xcode 27.0 (27A266), 743 of 752 items have one and 540 of those
/// name exactly one item. The identifiers did not move when the titles did:
/// `Toggle Comments` became `Comment Selection` and stayed `toggleComments:`. Keying on the
/// identifier is therefore both more stable *and* version-agnostic — there is no version
/// test anywhere in resolution, because the question asked is "is this command here?",
/// which the running Xcode answers for itself.
///
/// Three things the identifier does not do, each handled by a rule rather than a mechanism:
///
///   * **It is not always unique.** The dozen shared identifiers are the list-shaped menus —
///     `_userSelectedRunDestinationMenuItem:` names 102 items. That is exactly where a
///     picker wants the whole list, so a shared identifier is a description of the menu, not
///     a defect. A `MenuRef` disambiguates with a title when it wants one item.
///   * **It is not always present, or even stable.** Nine items have none. Worse, eight
///     `Editor >` toggles report a selector in one reading and a title in the next. Both
///     cases fall back to `MenuRef.path`, and the audit names them.
///   * **It is not documented.** It is AppKit exposing `NSMenuItem.action`, and most values
///     are selectors — but `File > Close Window` carries the identifier `Close Tab`, which
///     is not one. So it is matched as an opaque string and never parsed.
public enum MenuCatalogueSchema {
    /// Bumped when `MenuSnapshot`'s shape changes in a way an older reader cannot handle.
    /// 2 added `inputSource`, without which two snapshots cannot be compared on shortcuts.
    ///
    /// `editorScans` did **not** bump it, and that is the rule working: a reader that has
    /// never heard of the field ignores it and loses nothing it relied on, and a reader that
    /// has heard of it treats its absence as "never seen an editor", which is the safe answer.
    public static let current = 2

    /// A file written by a newer app than this one.
    ///
    /// Raised by `MenuSnapshot.decode` *before* the rest of the file is read, because a newer
    /// shape may not decode at all — and "could not decode" must not be mistaken for "nothing
    /// is there", or the store would write its older format over a newer user's knowledge.
    /// That is what a downgrade looks like from inside: the files outlive the app that wrote
    /// them in both directions.
    public struct NewerFile: Error, CustomStringConvertible {
        public var found: Int
        public var description: String {
            "written by a newer version (schema \(found); this one reads up to \(current))"
        }
    }
}

// MARK: - naming an item

/// How a command names the Xcode menu item it drives.
///
/// `identifier` is the key. `alternates` covers the one case the identifier cannot: Apple
/// renaming the action itself, which is rare enough that every `MenuRef` in the shipped
/// keymap leaves it empty, and cheap enough to carry for when it happens. `title`
/// disambiguates within a shared identifier. `path` is the escape hatch for the ten items
/// that have no identifier at all — never a fallback for the ones that do, because a path
/// that "works" by matching the wrong item is worse than one that fails.
public struct MenuRef: Hashable, Sendable, Codable {
    public var identifier: String
    public var alternates: [String]
    public var title: String?
    /// The exact menu path, used **only** when no identifier resolves.
    ///
    /// Reinstated after measurement, having once been removed on principle. Eight of Xcode
    /// 27's `Editor >` toggles — Minimap, Wrap Lines, Vim Mode, Invisibles, Relative Line
    /// Numbers, Authors, Code Coverage, Scope Guides — report a real selector
    /// (`toggleMinimapShown:`) in one reading and a title-shaped string (`Show Minimap`,
    /// `Hide Wrap Lines`) in another, flipping with the toggle's own state. For those an
    /// identifier is not an identity at all, and the app would lose eight keys to a
    /// principle.
    ///
    /// This is an **exact** match, never a prefix. The fallback that had to go was the one
    /// matching `File > Close “` against whatever document happened to be open; a whole path
    /// either names the item or it does not, and cannot quietly land somewhere else.
    public var path: [String]?

    public init(_ identifier: String, alternates: [String] = [],
                title: String? = nil, path: [String]? = nil) {
        self.identifier = identifier
        self.alternates = alternates
        self.title = title
        self.path = path
    }

    /// For the handful of items with no identifier. Resolution falls back to the path, and
    /// an audit can list these separately as the fragile ones.
    public static func pathOnly(_ path: [String]) -> MenuRef {
        MenuRef("", path: path)
    }

    public var isPathOnly: Bool { identifier.isEmpty && path != nil }

    /// The identifiers to try, in order.
    public var candidates: [String] {
        identifier.isEmpty ? alternates : [identifier] + alternates
    }
}

// MARK: - the snapshot

/// Which Xcode a snapshot came from.
///
/// `build` is the identity — `27A266` — because betas share a version string and differ in
/// exactly the ways this catalogue exists to notice. `major` is what the support floor is
/// expressed in, since Apple's version numbers have tracked the OS since 26.
public struct XcodeRelease: Hashable, Sendable, Codable {
    public var version: String
    public var build: String
    public var major: Int

    public init(version: String, build: String, major: Int) {
        self.version = version
        self.build = build
        self.major = major
    }

    /// The oldest Xcode this app claims to work on.
    ///
    /// Xcode 27 is the floor because it is the first release this app was measured against,
    /// and because Xcode 27 itself requires macOS 26.6 — so nobody who can run it is stuck
    /// below the line. Refusing clearly beats degrading mysteriously: a user on 26 should be
    /// told, on first run, rather than left to discover which keys do nothing.
    ///
    /// **The policy is Xcode 27 and later.** Earlier versions are never tested, so they are
    /// never claimed. The floor stays at 27 and the Xcode 27 capture stays in `Fixtures/` as
    /// the baseline. There is no ceiling, on purpose: resolution never asks which Xcode it is
    /// talking to, so a beta nobody has seen works on the first day, and the change report
    /// says what moved.
    public static let minimumMajor = 27

    public var isSupported: Bool { major >= Self.minimumMajor }
}

/// One menu item, as Accessibility reported it.
///
/// The shortcut is stored the way it arrived — character, modifier mask, virtual key — and
/// decoded on demand, so that a change to the decoding does not invalidate a snapshot
/// captured months earlier.
public struct MenuEntry: Hashable, Sendable, Codable {
    /// Empty for the ten items that have none.
    public var identifier: String
    public var title: String
    /// Where the item sat when the snapshot was taken. **Display and diagnostics only.**
    /// Nothing resolves through this except a `MenuRef` that has no identifier to use.
    public var path: [String]
    public var cmdChar: String?
    public var cmdModifiers: Int
    public var cmdVirtualKey: Int?

    public init(identifier: String, title: String, path: [String],
                cmdChar: String? = nil, cmdModifiers: Int = 0, cmdVirtualKey: Int? = nil) {
        self.identifier = identifier
        self.title = title
        self.path = path
        self.cmdChar = cmdChar
        self.cmdModifiers = cmdModifiers
        self.cmdVirtualKey = cmdVirtualKey
    }

    /// Whether a menu path belongs to macOS rather than to Xcode: the Apple menu, and
    /// `Xcode > Services`, which the system builds from the installed apps and the current
    /// selection. One rule, used by the scanner to leave them out and by the diff to ignore
    /// them in snapshots recorded before the scanner did.
    public static func isSystemOwned(_ path: [String]) -> Bool {
        path.first == "Apple" || Array(path.prefix(2)) == ["Xcode", "Services"]
    }

    /// The shortcut Xcode has for this item, in Core's vocabulary, or nil when it has none.
    public var shortcut: KeyEvent? {
        guard let character = cmdChar?.first else { return nil }
        return MenuShortcut.decode(character: character,
                                   mask: cmdModifiers,
                                   virtualKey: cmdVirtualKey)
    }
}

/// Every menu item one Xcode offered, in one context, at one moment.
///
/// **A snapshot records a context, not just a version.** Xcode's menus are context-dependent
/// in ways that look exactly like deletion: whole submenus are absent with no editor
/// focused, `Debug >` fills in only during a session, and `Find in Package` exists only when
/// a package is open. This is why `context` is stored and why an audit must never conclude
/// from a live scan alone that Apple removed something — it compares snapshots, which were
/// captured deliberately.
public struct MenuSnapshot: Sendable, Codable {
    public var schemaVersion: Int
    public var release: XcodeRelease
    public var capturedAt: String
    public var context: String
    /// The keyboard layout in effect when the menus were read, as a Text Input Source id —
    /// `com.apple.keylayout.French`.
    ///
    /// **Shortcuts are layout-dependent and nothing else in a snapshot is.** Xcode reports
    /// the *character* a shortcut produces, so on French AZERTY 28 of Xcode 27's items come
    /// back as `Ù`, `§`, `À`, `Ç` and friends where a US layout would report something else
    /// entirely. Identifiers, titles and paths are the same everywhere. Recording the layout
    /// is what lets `CatalogueDiff` tell "Apple rebound this" from "these two captures were
    /// taken on different keyboards", which it otherwise cannot, and would report 28 false
    /// changes every time two machines compared notes.
    ///
    /// Optional because a schema-1 snapshot has none, and those simply do not get compared
    /// on shortcuts.
    public var inputSource: String?
    public var entries: [MenuEntry]
    /// How many of the scans folded into this one were taken with a source editor focused.
    ///
    /// **This is the line between "not seen yet" and "not there".** Measured on Xcode 27.2:
    /// with only the Welcome window open — which is how Xcode comes back after an update —
    /// the menu bar has 509 items instead of 752, `Editor >` has 7 instead of 134, and 27 of
    /// the 115 shipped bindings are missing. With a project open but the navigator focused,
    /// four items go. An editor-focused read was the fullest of every context measured, so
    /// until a build has had one, its accumulated menu is a partial picture, and nothing may
    /// be hidden or reported as removed on the strength of it. See `isSettled`.
    ///
    /// Optional because snapshots written before this field existed have none — and reading
    /// those as unsettled costs at most one session of showing every key.
    public var editorScans: Int?

    public init(schemaVersion: Int = MenuCatalogueSchema.current,
                release: XcodeRelease, capturedAt: String, context: String,
                inputSource: String? = nil, entries: [MenuEntry], editorScans: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.release = release
        self.capturedAt = capturedAt
        self.context = context
        self.inputSource = inputSource
        self.entries = entries
        self.editorScans = editorScans
    }

    /// Whether this snapshot has seen enough of Xcode to say a command is missing.
    ///
    /// The app shows everything until this is true, and only then hides keys or writes the
    /// change report. Waiting costs a session at worst; not waiting tells a user that Apple
    /// removed 27 of their commands because Xcode came back from its update on the Welcome
    /// window.
    public var isSettled: Bool { (editorScans ?? 0) > 0 }

    /// Fold another scan of the *same* Xcode into this one.
    ///
    /// **This is what makes "Apple removed it" a knowable fact.** A single scan is a record
    /// of one context — `Debug >` fills in only during a session, whole submenus are absent
    /// with no editor focused — so one scan can never tell a deleted command from a command
    /// that simply does not apply this second. Union enough scans of the same build and the
    /// picture converges on everything that Xcode *can* offer; anything still missing is
    /// missing for real.
    ///
    /// Later entries win on title and shortcut, because the newest reading of a live menu is
    /// the truest one. Returns self unchanged when the builds differ, since folding two
    /// Xcodes together would invent a menu neither of them has.
    public func merging(_ other: MenuSnapshot) -> MenuSnapshot {
        guard other.release.build == release.build else { return self }
        var byPath: [[String]: MenuEntry] = [:]
        for entry in entries { byPath[entry.path] = entry }
        for entry in other.entries { byPath[entry.path] = entry }

        // **A toggle changes its own title, and a naive union would clone it.**
        // `View > Navigators > Show Navigator` becomes `Hide Navigator` the moment the
        // navigator opens, so two captures taken either side of that keep both paths — and
        // `toggleNavigator:` would then name two items and resolve as ambiguous, which is
        // how an accumulating store could break the very commands it exists to protect.
        //
        // An identifier names one command, so when it was unique in each snapshot and the
        // paths differ, they are the same item seen in two states and the newer reading
        // wins. A genuinely list-shaped identifier — 102 run destinations sharing one
        // action — is *not* unique within either snapshot, so it is left alone.
        func uniquePaths(_ snapshot: MenuSnapshot) -> [String: [String]] {
            var counts: [String: Int] = [:]
            var paths: [String: [String]] = [:]
            for entry in snapshot.entries where !entry.identifier.isEmpty {
                counts[entry.identifier, default: 0] += 1
                paths[entry.identifier] = entry.path
            }
            return paths.filter { counts[$0.key] == 1 }
        }
        let mine = uniquePaths(self), theirs = uniquePaths(other)
        for (identifier, newPath) in theirs {
            guard let oldPath = mine[identifier], oldPath != newPath else { continue }
            byPath.removeValue(forKey: oldPath)
        }

        var merged = self
        merged.entries = byPath.values.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        merged.capturedAt = max(capturedAt, other.capturedAt)
        // Shortcuts are only comparable within one layout, so a merge across two keyboards
        // has to stop claiming one. Everything else in the snapshot still merges cleanly.
        merged.inputSource = inputSource == other.inputSource ? inputSource : nil
        if editorScans != nil || other.editorScans != nil {
            merged.editorScans = (editorScans ?? 0) + (other.editorScans ?? 0)
        }
        let contexts = Set(context.split(separator: "\n").map(String.init))
            .union(other.context.split(separator: "\n").map(String.init))
        merged.context = contexts.sorted().joined(separator: "\n")
        return merged
    }

    /// Read a snapshot, refusing one written by a newer app.
    ///
    /// The version is read on its own first. Everything that loads a snapshot — the store,
    /// `xcmdr diff`, the tests — comes through here, so the check lives in exactly one place.
    public static func decode(_ data: Data) throws -> MenuSnapshot {
        struct Header: Decodable { var schemaVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schemaVersion <= MenuCatalogueSchema.current else {
            throw MenuCatalogueSchema.NewerFile(found: header.schemaVersion)
        }
        return try JSONDecoder().decode(MenuSnapshot.self, from: data)
    }

    /// Sorted keys and pretty printing, so two captures of the same Xcode diff to nothing
    /// and two captures of different Xcodes diff to what Apple changed.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - resolving against it

/// How a `MenuRef` was found, so an audit can say when the good key failed.
public enum ResolutionRoute: Hashable, Sendable {
    /// By `AXIdentifier`. What should happen, and what happens for all but eight bindings.
    case identifier
    /// By exact menu path, because no identifier resolved. See `MenuRef.path`.
    case path
}

public enum MenuResolution: Hashable, Sendable {
    case bound(MenuEntry, via: ResolutionRoute)
    /// The identifier names a list and the ref did not say which item it wanted.
    case ambiguous([MenuEntry])
    case unbound
}

/// A snapshot indexed for lookup.
public struct MenuCatalogue: Sendable {
    public let release: XcodeRelease
    public let context: String
    public let inputSource: String?
    /// Carried over from the snapshot: whether a miss here means anything. See
    /// `MenuSnapshot.isSettled`.
    public let isSettled: Bool
    private let byIdentifier: [String: [MenuEntry]]
    private let byPath: [[String]: MenuEntry]
    public let entries: [MenuEntry]

    public init(_ snapshot: MenuSnapshot) {
        release = snapshot.release
        context = snapshot.context
        inputSource = snapshot.inputSource
        isSettled = snapshot.isSettled
        entries = snapshot.entries
        var identifiers: [String: [MenuEntry]] = [:]
        var paths: [[String]: MenuEntry] = [:]
        for entry in snapshot.entries {
            if !entry.identifier.isEmpty { identifiers[entry.identifier, default: []].append(entry) }
            // Two items can share a path: `Window > Move & Resize > Quarters` is both a
            // section header and a command, and only one of them does anything. Prefer the
            // one with an identifier, which is one more reason a path is a poor key.
            if paths[entry.path] == nil || (paths[entry.path]!.identifier.isEmpty && !entry.identifier.isEmpty) {
                paths[entry.path] = entry
            }
        }
        byIdentifier = identifiers
        byPath = paths
    }

    public func resolve(_ ref: MenuRef) -> MenuResolution {
        for candidate in ref.candidates {
            guard let matches = byIdentifier[candidate], !matches.isEmpty else { continue }
            if matches.count == 1 { return .bound(matches[0], via: .identifier) }
            // A shared identifier: the ref must say which one it means.
            guard let title = ref.title else { return .ambiguous(matches) }
            if let hit = matches.first(where: { $0.title == title }) {
                return .bound(hit, via: .identifier)
            }
            return .ambiguous(matches)
        }
        // Only now, and only for a ref that wrote a path down.
        if let path = ref.path, let hit = byPath[path] { return .bound(hit, via: .path) }
        return .unbound
    }

    public func isBound(_ ref: MenuRef) -> Bool {
        if case .bound = resolve(ref) { return true }
        return false
    }

    /// How a ref resolves, or nil when it does not. The audit wants to know both that a
    /// binding works and whether it works for the right reason.
    public func route(of ref: MenuRef) -> ResolutionRoute? {
        if case .bound(_, let via) = resolve(ref) { return via }
        return nil
    }

    /// Every item under a menu path, for the pickers that present a whole submenu.
    /// Keyed by path rather than identifier on purpose: this asks a question about the
    /// *menu's shape*, which is what a submenu is.
    public func items(under prefix: [String]) -> [MenuEntry] {
        entries
            .filter { $0.path.count == prefix.count + 1 && Array($0.path.prefix(prefix.count)) == prefix }
            .sorted { $0.title < $1.title }
    }

    /// Every item Xcode has put on this exact chord.
    ///
    /// For the leader check: a leader is swallowed while Xcode is frontmost, so whatever
    /// Xcode bound to the same chord becomes unreachable. Trustworthy for the leaders this
    /// app offers because every one of them is over a key that produces no character —
    /// Return, Space, Escape — and those decode the same on every keyboard layout.
    public func entries(withShortcut chord: KeyEvent) -> [MenuEntry] {
        entries.filter { $0.shortcut == chord }
    }

    public var identifierCount: Int { byIdentifier.count }
    public var unnamedEntries: [MenuEntry] { entries.filter(\.identifier.isEmpty) }
}

// MARK: - what changed between two Xcodes

public struct MenuChange: Hashable, Sendable {
    public var identifier: String
    public var before: String
    public var after: String
}

/// The difference between two snapshots.
///
/// `retitled` and `moved` are not failures — they are the churn the identifier absorbs, and
/// they are reported because they make documentation and the palette's grouping stale. `removed` is the only category that costs a user a key, and even then the right
/// response is usually to keep the binding: it still resolves on the Xcode that has it.
public struct CatalogueDiff: Sendable {
    public var added: [MenuEntry] = []
    public var removed: [MenuEntry] = []
    public var retitled: [MenuChange] = []
    public var moved: [MenuChange] = []
    public var rebound: [MenuChange] = []
    /// False when the two snapshots were captured under different keyboard layouts, or when
    /// either does not say which. `rebound` is then empty because it was never computed —
    /// which an audit should report as "not compared", not as "nothing changed".
    public var shortcutsCompared: Bool = true

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && retitled.isEmpty && moved.isEmpty && rebound.isEmpty
    }

    /// Items with no identifier cannot be tracked across versions — there is nothing to
    /// follow them by — so they take no part in the diff rather than appearing as an
    /// added/removed pair on every capture.
    ///
    /// **Most title changes are not Apple's.** The first real upgrade this ran on — 27.0 to
    /// 27.2 — reported seventeen renames, and four were plausibly Apple's. The rest were the
    /// open file's name inside a title (`Compile “AppDelegate.swift”`), a toggle reporting
    /// its other state (`Continue` / `Pause`), and the window list, which is the user's data.
    /// So titles are compared with quoted names blanked out, and a list-shaped identifier —
    /// one naming several items in either snapshot — takes part only in added and removed.
    /// What is left is still not proof, which is why the report calls them titles that
    /// changed rather than commands Apple renamed.
    public static func between(_ old: MenuSnapshot, and new: MenuSnapshot) -> CatalogueDiff {
        func index(_ snapshot: MenuSnapshot) -> (first: [String: MenuEntry], shared: Set<String>) {
            var result: [String: MenuEntry] = [:]
            var shared: Set<String> = []
            for entry in snapshot.entries
            where !entry.identifier.isEmpty && !MenuEntry.isSystemOwned(entry.path) {
                if result[entry.identifier] == nil { result[entry.identifier] = entry }
                else { shared.insert(entry.identifier) }
            }
            return (result, shared)
        }
        let (before, sharedBefore) = index(old), (after, sharedAfter) = index(new)
        let listShaped = sharedBefore.union(sharedAfter)
        var diff = CatalogueDiff()
        // Same keyboard, or no opinion about shortcuts at all.
        diff.shortcutsCompared = old.inputSource != nil && old.inputSource == new.inputSource
        for (identifier, entry) in after where before[identifier] == nil {
            diff.added.append(entry)
        }
        for (identifier, entry) in before where after[identifier] == nil {
            diff.removed.append(entry)
        }
        for (identifier, was) in before {
            guard let now = after[identifier], !listShaped.contains(identifier) else { continue }
            if contextFree(was.title) != contextFree(now.title) {
                diff.retitled.append(MenuChange(identifier: identifier, before: was.title, after: now.title))
            }
            if was.path.dropLast() != now.path.dropLast() {
                diff.moved.append(MenuChange(identifier: identifier,
                                             before: was.path.dropLast().joined(separator: " > "),
                                             after: now.path.dropLast().joined(separator: " > ")))
            }
            if diff.shortcutsCompared, was.shortcut != now.shortcut {
                diff.rebound.append(MenuChange(identifier: identifier,
                                               before: was.shortcut?.display ?? "—",
                                               after: now.shortcut?.display ?? "—"))
            }
        }
        diff.added.sort { $0.identifier < $1.identifier }
        diff.removed.sort { $0.identifier < $1.identifier }
        diff.retitled.sort { $0.identifier < $1.identifier }
        diff.moved.sort { $0.identifier < $1.identifier }
        diff.rebound.sort { $0.identifier < $1.identifier }
        return diff
    }

    /// A title with every quoted name blanked: `Close “Notes.swift”` and `Close “main.swift”`
    /// are the same command looking at different files.
    public static func contextFree(_ title: String) -> String {
        var out = "", quoted = false
        for character in title {
            switch character {
            case "“": quoted = true; out.append("“…")
            case "”": quoted = false; out.append("”")
            default: if !quoted { out.append(character) }
            }
        }
        return out
    }
}
