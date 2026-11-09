import AppKit
import ApplicationServices
import Foundation
import XCommanderCore
import XcodeMenus

// xcmdr: XCommander and Xcode's menus.
//
// It reads Xcode's menus with the same code the app uses, so what it reports is what ships.
// Anyone can run it. Contributors use the first group, mostly to report a problem or to help
// with an Xcode beta; the maintainer uses all of it to check each new Xcode before a release.
//
// Look and report (anyone):
//   xcmdr doctor                     is this machine fit to build and run the app
//   xcmdr list [--under "A > B"]     browse a menu
//   xcmdr resolve <identifier>       where does this action live right now
//   xcmdr run <identifier>           press one menu item, as the app would (drives Xcode)
//   xcmdr press <button> <id>        press one toolbar popup item (drives Xcode)
//   xcmdr builds                     which Xcodes this machine has recorded
//
// Capture and check an Xcode (contributors on a beta, and the maintainer):
//   xcmdr snapshot [-o f] [-c note]  capture the running Xcode's menus
//   xcmdr merge <a> <b>              union two captures of one Xcode, taken in two contexts
//   xcmdr audit [--snapshot f]       do the shipped bindings resolve
//   xcmdr diff <old> <new>           what Apple changed between two snapshots
//   xcmdr popups                     check the toolbar popups Xcode hides commands in
//
// Maintainer:
//   xcmdr reference [--snapshot f]   the website's command reference, as Markdown
//
// Every snapshot it writes is redacted (`MenuSnapshot.redacted`): Xcode's menus also list
// recent projects, device names, windows and schemes, and a capture is made to be shared.
//
// With several Xcodes running, `--xcode PATH` says which one; otherwise the app's own rule
// picks, and the choice is printed.
//
// Exit codes: 0 fine, 1 findings to look at, 2 could not run.

let out = FileHandle.standardOutput
let err = FileHandle.standardError
func emit(_ s: String = "") { out.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { err.write(("xcmdr: " + s + "\n").data(using: .utf8)!); exit(2) }

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var bools: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let token = raw[i]
            if token.hasPrefix("--") || (token.hasPrefix("-") && token.count == 2) {
                let name = String(token.drop(while: { $0 == "-" }))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("-") {
                    flags[name] = raw[i + 1]; i += 2; continue
                }
                bools.insert(name)
            } else {
                positional.append(token)
            }
            i += 1
        }
    }
    func value(_ names: String...) -> String? { names.compactMap { flags[$0] }.first }
    func has(_ names: String...) -> Bool { names.contains { bools.contains($0) } }
}

let argv = Array(CommandLine.arguments.dropFirst())
let args = Args(argv)
let json = args.has("json")

func usage() -> Never {
    emit("""
    xcmdr — XCommander and Xcode's menus

    LOOK AND REPORT
      xcmdr doctor                          check this machine
      xcmdr list [--under "Product > Run"]  browse a menu
      xcmdr resolve IDENTIFIER              locate an action
      xcmdr run IDENTIFIER                  press one menu item (drives Xcode)
      xcmdr press BUTTON IDENTIFIER         press one popup item (drives Xcode)
      xcmdr builds                          Xcodes recorded on this machine

    CAPTURE AND CHECK AN XCODE
      xcmdr snapshot [-o FILE] [-c NOTE]    capture the running Xcode's menus (redacted)
      xcmdr merge A.json B.json -o OUT      union two captures of the same Xcode
      xcmdr audit [--snapshot FILE]         check every shipped binding
      xcmdr diff OLD.json NEW.json          what Apple changed
      xcmdr popups                          check the toolbar popups (opens them)

    MAINTAINER
      xcmdr reference [-o FILE]             the website's command reference page

    OPTIONS
      --snapshot FILE   audit against a file instead of the running Xcode
      --json            machine-readable output
      -o, --output FILE where to write
      -c, --context     a note describing what was on screen during a capture
      --no-activate     do not bring Xcode forward first (its menus will be incomplete)
      --xcode PATH|PID  which Xcode, when more than one is running
    """)
    exit(args.positional.isEmpty ? 2 : 0)
}

/// Which Xcode this run is about.
///
/// **Every copy of Xcode shares one bundle identifier**, so with a release and a beta both
/// open "the running Xcode" means nothing. `--xcode` names one by path, or by pid when two
/// copies of the same app are running. Otherwise the app's own rule picks (`XcodeTarget`),
/// and a line on stderr says which — by path *and* pid, since two processes can share a path
/// — because an audit of the wrong Xcode that looks like an audit of the right one is the
/// worst output this tool can give.
var chosenXcode: NSRunningApplication??
@MainActor
func targetXcode() -> NSRunningApplication? {
    if let chosenXcode { return chosenXcode }
    let running = MenuScanner.runningXcodes
    var chosen: NSRunningApplication?
    if let named = args.value("xcode") {
        if let pid = pid_t(named) {
            guard let match = running.first(where: { $0.processIdentifier == pid })
            else { fail("no running Xcode with pid \(pid)") }
            chosen = match
        } else {
            let wanted = URL(fileURLWithPath: named).standardizedFileURL.path
            let matches = running.filter { $0.bundleURL?.standardizedFileURL.path == wanted }
            guard let match = matches.first else { fail("no running Xcode at \(named)") }
            guard matches.count == 1 else {
                fail("\(matches.count) Xcodes are running from \(named) (pids "
                     + "\(matches.map { String($0.processIdentifier) }.joined(separator: ", "))); pass --xcode PID")
            }
            chosen = match
        }
    } else {
        chosen = MenuScanner.target()
        if running.count > 1, let chosen {
            err.write(("xcmdr: \(running.count) Xcodes are running; using "
                       + "\(chosen.bundleURL?.path ?? "?") (pid \(chosen.processIdentifier)). "
                       + "Pass --xcode PATH or PID to choose.\n").data(using: .utf8)!)
        }
    }
    chosenXcode = .some(chosen)
    return chosen
}

/// Read a snapshot file, or stop with the reason — including "written by a newer version".
func readSnapshot(_ path: String) -> MenuSnapshot {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    do { return try MenuSnapshot.decode(data) }
    catch let newer as MenuCatalogueSchema.NewerFile { fail("\(path) was \(newer)") }
    catch { fail("\(path) is not a snapshot") }
}

/// Bring Xcode to the front, and put the previous app back afterwards.
///
/// **Xcode's menus do not answer while it is in the background.** A capture taken from a
/// terminal that still has focus is quietly incomplete — the `Editor >` toggles vanish and
/// the snapshot then "proves" that eight commands were removed. This is the same trap that
/// once made a whole menu dump look empty, and it is worth paying half a second to avoid.
@discardableResult
@MainActor
func withXcodeFrontmost<T>(_ body: (NSRunningApplication?) -> T) -> T {
    let xcode = targetXcode()
    let previous = NSWorkspace.shared.frontmostApplication
    // Compared by process, not bundle identifier: with two Xcodes open, the other one being
    // in front is exactly the case where this one still needs bringing forward.
    if let xcode, previous?.processIdentifier != xcode.processIdentifier {
        xcode.activate()
        usleep(500_000)
        defer { usleep(150_000); previous?.activate() }
        return body(xcode)
    }
    return body(xcode)
}

/// A snapshot to work against: a file if one is named, otherwise the running Xcode.
@MainActor
func snapshotSource(_ args: Args, context: String) -> MenuSnapshot {
    if let path = args.value("snapshot", "s") { return readSnapshot(path) }
    if args.has("no-activate") {
        do { return try MenuScanner.scan(of: targetXcode(), context: context, timeout: 10).snapshot }
        catch { fail("\(error)") }
    }
    let result = withXcodeFrontmost { try? MenuScanner.scan(of: $0, context: context, timeout: 10) }
    guard let result else { fail("could not read Xcode's menus") }
    return result.snapshot
}

func jsonOut(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                 options: [.prettyPrinted, .sortedKeys]) else { return }
    out.write(data); emit()
}

guard let command = args.positional.first else { usage() }

switch command {

// MARK: - doctor

case "doctor":
    var problems = 0
    emit("XCommander environment")
    emit("")

    let trusted = MenuScanner.hasAccessibility
    emit("  Accessibility permission   \(trusted ? "granted" : "MISSING")")
    if !trusted { problems += 1 }

    let xcode = targetXcode()
    if let xcode, let release = MenuScanner.release(of: xcode) {
        let ok = release.isSupported
        emit("  Xcode running              \(release.version) (\(release.build))\(ok ? "" : "  BELOW THE FLOOR")")
        if !ok { problems += 1 }
        let others = MenuScanner.runningXcodes.count - 1
        if others > 0 {
            emit("  Other Xcodes running       \(others) — checked: \(xcode.bundleURL?.path ?? "?")")
        }
    } else {
        emit("  Xcode running              none")
    }
    emit("  Minimum supported          Xcode \(XcodeRelease.minimumMajor)")
    emit("  Keyboard layout            \(MenuScanner.currentInputSource() ?? "unknown")")

    // The two libraries the pickers need, resolved the way the app resolves them.
    let selected = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    emit("  Selected toolchain         \(selected.isEmpty ? "unknown" : selected)")
    for (label, relative) in [
        ("libIndexStore", "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"),
        ("sourcekitdInProc", "/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitdInProc.framework/Versions/A/sourcekitdInProc"),
    ] {
        let present = !selected.isEmpty && FileManager.default.fileExists(atPath: selected + relative)
        emit("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(present ? "found" : "MISSING")")
        if !present { problems += 1 }
    }

    // The window's shape, which is the part no identifier protects.
    emit("")
    emit("  Window assumptions")
    for finding in XcodeAXSchema.selfCheck(of: xcode) {
        emit("    \(finding.holds ? "ok  " : "??  ")\(finding.assumption)")
        emit("        \(finding.detail)")
    }

    // What each leader would hide in *this* Xcode, against what the settings window says.
    // Read with Xcode in front, like `audit`: a background read is partial, and a partial read
    // would report notes as stale that are not.
    let leaderScan = xcode == nil ? nil
        : args.has("no-activate")
            ? try? MenuScanner.scan(of: xcode, context: "xcmdr doctor", timeout: 10)
            : withXcodeFrontmost { try? MenuScanner.scan(of: $0, context: "xcmdr doctor", timeout: 10) }
    if let scan = leaderScan {
        emit("")
        emit("  Leader keys")
        let catalogue = MenuCatalogue(scan.snapshot)
        for choice in LeaderChoice.allCases {
            let hidden = catalogue.entries(withShortcut: choice.event).map(\.title)
            let (undeclared, found) = choice.unexpectedShadows(in: catalogue)
            // Something on the chord is proof. Something *missing* from it proves nothing
            // unless an editor had focus, since half of Editor > is absent otherwise.
            let stale = catalogue.isSettled ? found : []
            let agrees = undeclared.isEmpty && stale.isEmpty
            if !agrees { problems += 1 }
            emit("    \(agrees ? "ok  " : "!!  ")\(choice.title.padding(toLength: 12, withPad: " ", startingAt: 0))"
                 + (hidden.isEmpty ? "hides nothing in the menus" : "hides \(hidden.joined(separator: ", "))")
                 + (agrees ? "" : " — its note says otherwise"))
        }
    }

    let store = SnapshotStore()
    let builds = store.knownBuilds()
    emit("")
    emit("  Recorded Xcode builds      \(builds.isEmpty ? "none" : builds.map(\.build).joined(separator: ", "))")
    emit("")
    emit(problems == 0 ? "No problems." : "\(problems) problem\(problems == 1 ? "" : "s").")
    exit(problems == 0 ? 0 : 1)

// MARK: - snapshot

case "snapshot":
    let context = args.value("context", "c")
        ?? "captured by xcmdr; context not described"
    let scan: MenuScanner.Scan
    if args.has("no-activate") {
        do { scan = try MenuScanner.scan(of: targetXcode(), context: context, timeout: 10) }
        catch { fail("\(error)") }
    } else {
        guard let result = withXcodeFrontmost({ try? MenuScanner.scan(of: $0, context: context, timeout: 10) })
        else { fail("could not read Xcode's menus — is it running?") }
        scan = result
    }
    // Redacted because a capture is made to be shared (a fixture, an issue), and Xcode's
    // menus list recent projects and device names along with its commands.
    let snapshot = scan.snapshot.redacted()
    let destination = args.value("output", "o")
        ?? "Fixtures/Xcode-\(snapshot.release.build).json"
    do {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try snapshot.encoded().write(to: URL(fileURLWithPath: destination), options: .atomic)
    } catch { fail("cannot write \(destination): \(error)") }
    let named = snapshot.entries.filter { !$0.identifier.isEmpty }.count
    emit("\(snapshot.entries.count) items, \(named) with an identifier → \(destination)")
    emit("Xcode \(snapshot.release.version) (\(snapshot.release.build)), keyboard \(snapshot.inputSource ?? "unknown")")
    emit("context: \(snapshot.context)")
    if !snapshot.isSettled {
        emit("no source editor had focus: this capture may be missing commands (unsettled)")
    }

// MARK: - audit

case "audit":
    let snapshot = snapshotSource(args, context: "xcmdr audit")
    let catalogue = MenuCatalogue(snapshot)
    var bound = 0
    var unbound: [Command] = []
    var ambiguous: [Command] = []
    var actionless: [(Command, [String])] = []
    var pathBound: [Command] = []

    // Every leader's note against this Xcode. Checked for all of them, not just the default,
    // because the settings window offers all of them and states each one's cost.
    // A declared item missing from the chord only counts in a settled snapshot: without an
    // editor focused, half of Editor > is absent and its shortcuts with it.
    var leaderFindings: [String] = []
    for choice in LeaderChoice.allCases {
        let (undeclared, found) = choice.unexpectedShadows(in: catalogue)
        for entry in undeclared {
            leaderFindings.append("\(choice.title) now hides \(entry.path.joined(separator: " > ")) (\(entry.identifier))")
        }
        for identifier in catalogue.isSettled ? found : [] {
            leaderFindings.append("\(choice.title) no longer hides \(identifier), but its note says it does")
        }
    }

    for command in DefaultKeymap.menuCommands {
        let ref = command.menuRef!
        switch catalogue.resolve(ref) {
        case .bound(let entry, let via):
            bound += 1
            // Working, but not for the right reason: the identifier failed and the written
            // path caught it. Worth seeing, because a path is the fragile key.
            if via == .path { pathBound.append(command) }
            if entry.identifier.isEmpty { actionless.append((command, entry.path)) }
        case .ambiguous: ambiguous.append(command)
        case .unbound: unbound.append(command)
        }
    }

    if json {
        jsonOut([
            "build": snapshot.release.build,
            "version": snapshot.release.version,
            "total": DefaultKeymap.menuCommands.count,
            "bound": bound,
            "unbound": unbound.map(\.id),
            "ambiguous": ambiguous.map(\.id),
            "actionless": actionless.map(\.0.id),
            "pathBound": pathBound.map(\.id),
            "leaderFindings": leaderFindings,
        ])
    } else {
        emit("Auditing \(DefaultKeymap.menuCommands.count) shipped bindings against Xcode \(snapshot.release.version) (\(snapshot.release.build))")
        emit("context: \(snapshot.context)")
        emit("")
        emit("  bound                    \(bound)")
        emit("  unbound                  \(unbound.count)")
        emit("  ambiguous                \(ambiguous.count)")
        emit("  bound only by path       \(pathBound.count)")
        emit("  resolves to no action    \(actionless.count)")
        // Popups are not in the menu bar, so a snapshot cannot speak for them. Saying so
        // beats quietly auditing three fewer commands than the app ships.
        let popups = DefaultKeymap.popupCommands
        if !popups.isEmpty {
            emit("  in toolbar popups        \(popups.count) — not checked here; run `xcmdr popups`")
        }
        for command in unbound {
            emit("\n  UNBOUND  \(command.id) — \(command.title)")
            let ref = command.menuRef!
            emit("           wanted \(ref.isPathOnly ? (ref.path ?? []).joined(separator: " > ") : ref.identifier)")
        }
        for command in ambiguous {
            emit("\n  AMBIGUOUS \(command.id) — \(command.menuRef!.identifier) names several items; add a title")
        }
        for (command, path) in actionless {
            emit("\n  NO ACTION \(command.id) — resolves to \(path.joined(separator: " > ")), which cannot be pressed")
        }
        for command in pathBound {
            emit("\n  BY PATH  \(command.id) — the identifier did not resolve; fell back to the menu path")
        }
        for finding in leaderFindings {
            emit("\n  LEADER   \(finding) — update `LeaderChoice.shadows` and its note")
        }
        emit("")
    }
    exit(unbound.isEmpty && ambiguous.isEmpty && actionless.isEmpty && leaderFindings.isEmpty ? 0 : 1)

// MARK: - diff

case "diff":
    guard args.positional.count >= 3 else { fail("diff needs two snapshot files") }
    let old = readSnapshot(args.positional[1]), new = readSnapshot(args.positional[2])
    let diff = CatalogueDiff.between(old, and: new)
    let lost = DefaultKeymap.menuCommands.filter {
        MenuCatalogue(old).isBound($0.menuRef!) && !MenuCatalogue(new).isBound($0.menuRef!)
    }
    if json {
        jsonOut([
            "from": old.release.build, "to": new.release.build,
            "added": diff.added.map(\.identifier),
            "removed": diff.removed.map(\.identifier),
            "retitled": diff.retitled.map { ["identifier": $0.identifier, "before": $0.before, "after": $0.after] },
            "moved": diff.moved.map { ["identifier": $0.identifier, "before": $0.before, "after": $0.after] },
            "rebound": diff.rebound.map { ["identifier": $0.identifier, "before": $0.before, "after": $0.after] },
            "shortcutsCompared": diff.shortcutsCompared,
            "lostBindings": lost.map(\.id),
        ])
    } else {
        emit("Xcode \(old.release.version) (\(old.release.build)) → \(new.release.version) (\(new.release.build))")
        emit("")
        emit("  added      \(diff.added.count)")
        emit("  removed    \(diff.removed.count)")
        emit("  retitled   \(diff.retitled.count)")
        emit("  moved      \(diff.moved.count)")
        emit("  rebound    \(diff.shortcutsCompared ? String(diff.rebound.count) : "not compared (different keyboard layouts)")")
        if !lost.isEmpty {
            emit("\n  BINDINGS LOST:")
            for command in lost { emit("    \(command.id) — \(command.title)") }
        }
        for change in diff.retitled { emit("\n  retitled  \(change.before) → \(change.after)") }
        for change in diff.moved { emit("\n  moved     \(change.identifier): \(change.before) → \(change.after)") }
        if diff.shortcutsCompared {
            for change in diff.rebound { emit("\n  rebound   \(change.identifier): \(change.before) → \(change.after)") }
        }
        emit("")
    }
    exit(lost.isEmpty ? 0 : 1)

// MARK: - list

case "merge":
    // **One capture is never a superset.** Focus the editor and the `Editor >` toggles
    // appear while the navigator's items do not; open the navigator and the reverse happens,
    // because focus left the editor. A fixture worth testing against is the union of several
    // deliberate captures, which is the same thing the app's store builds at runtime.
    guard args.positional.count >= 3 else { fail("merge needs two snapshot files") }
    let first = readSnapshot(args.positional[1]), second = readSnapshot(args.positional[2])
    guard first.release.build == second.release.build else {
        fail("these are different Xcodes (\(first.release.build) and \(second.release.build)); merging them would invent a menu neither has")
    }
    let union = first.merging(second).redacted()
    let target = args.value("output", "o") ?? args.positional[1]
    do { try union.encoded().write(to: URL(fileURLWithPath: target), options: .atomic) }
    catch { fail("cannot write \(target): \(error)") }
    emit("\(first.entries.count) + \(second.entries.count) → \(union.entries.count) items → \(target)")
    // A union can come out *smaller* than either input, and that is the toggle rule working:
    // `Show Navigator` and `Hide Navigator` are one command seen twice, and collapsing them is
    // what stops the identifier resolving as ambiguous.
    let widest = max(first.entries.count, second.entries.count)
    if union.entries.count >= widest {
        let gained = union.entries.count - widest
        emit("\(gained) item\(gained == 1 ? "" : "s") that neither capture had on its own")
    } else {
        let collapsed = widest - union.entries.count
        emit("\(collapsed) item\(collapsed == 1 ? "" : "s") collapsed: the same command seen in two states")
    }

case "list":
    let snapshot = snapshotSource(args, context: "xcmdr list")
    let catalogue = MenuCatalogue(snapshot)
    let entries: [MenuEntry]
    if let under = args.value("under", "u") {
        let prefix = under.components(separatedBy: ">").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        entries = catalogue.items(under: prefix)
    } else {
        entries = catalogue.entries
    }
    if json {
        jsonOut(entries.map { ["identifier": $0.identifier, "title": $0.title,
                               "path": $0.path, "shortcut": $0.shortcut?.display ?? ""] })
    } else {
        for entry in entries {
            let shortcut = entry.shortcut.map { "  \($0.display)" } ?? ""
            emit("\(entry.path.joined(separator: " > "))".padding(toLength: 62, withPad: " ", startingAt: 0)
                 + (entry.identifier.isEmpty ? "—" : entry.identifier) + shortcut)
        }
        emit("\n\(entries.count) items")
    }

// MARK: - resolve

case "resolve":
    guard args.positional.count >= 2 else { fail("resolve needs an identifier") }
    let wanted = args.positional[1]
    let snapshot = snapshotSource(args, context: "xcmdr resolve")
    switch MenuCatalogue(snapshot).resolve(MenuRef(wanted)) {
    case .bound(let entry, _):
        emit("\(entry.path.joined(separator: " > "))")
        emit("  title     \(entry.title)")
        emit("  shortcut  \(entry.shortcut?.display ?? "none")")
    case .ambiguous(let all):
        emit("\(wanted) names \(all.count) items:")
        for entry in all { emit("  \(entry.path.joined(separator: " > "))") }
        exit(1)
    case .unbound:
        emit("\(wanted) is not in Xcode \(snapshot.release.version)")
        exit(1)
    }

// MARK: - builds

case "popups":
    // Opens each popup the keymap depends on and reads it. It moves the UI, so it is its own
    // command rather than part of `audit` — a maintenance tool may interrupt, but only when
    // asked.
    guard MenuScanner.hasAccessibility else { fail("no Accessibility permission") }
    guard let xcode = targetXcode() else { fail("Xcode is not running") }
    let wanted = DefaultKeymap.popupCommands.compactMap(\.popupRef)
    guard !wanted.isEmpty else { emit("no popup-backed commands"); exit(0) }
    let previous = NSWorkspace.shared.frontmostApplication
    xcode.activate()
    usleep(400_000)
    var missing: [PopupMenuRef] = []
    for button in Set(wanted.map(\.button)).sorted() {
        let items = PopupReader.read(button: button, pid: xcode.processIdentifier)
        emit("\(button):")
        if items.isEmpty { emit("   (could not open)") }
        for item in items {
            emit("   \"\(item.title)\"".padding(toLength: 34, withPad: " ", startingAt: 0) + item.identifier)
        }
        for ref in wanted where ref.button == button {
            if !items.contains(where: { $0.identifier == ref.item.identifier }) { missing.append(ref) }
        }
        emit("")
    }
    previous?.activate()
    if missing.isEmpty {
        emit("all \(wanted.count) popup-backed commands are present")
    } else {
        for ref in missing { emit("MISSING  \(ref.item.identifier) in \(ref.button)") }
    }
    exit(missing.isEmpty ? 0 : 1)

case "run":
    // Presses a menu item by identifier, which is how any shipped command can be tried by
    // hand — no app running, no leader key, no guessing whether a binding works.
    guard args.positional.count >= 2 else { fail("run needs an identifier") }
    guard MenuScanner.hasAccessibility else { fail("no Accessibility permission") }
    guard let xcode = targetXcode() else { fail("Xcode is not running") }
    // Xcode's menus do not answer while it is in the background, which is the trap that
    // once made a whole menu dump look empty.
    let wasFrontmost = NSWorkspace.shared.frontmostApplication
    xcode.activate()
    usleep(400_000)
    guard let scan = try? MenuScanner.scan(of: xcode, context: "xcmdr run", timeout: 10) else {
        fail("could not read Xcode's menus")
    }
    let wantedRef = MenuRef(args.positional[1], title: args.value("title", "t"))
    guard case .bound(let entry, _) = MenuCatalogue(scan.snapshot).resolve(wantedRef),
          let element = scan.elements[entry.path] else {
        wasFrontmost?.activate()
        emit("\(args.positional[1]) is not in Xcode \(scan.snapshot.release.version)")
        exit(1)
    }
    let ok = AXUIElementPerformAction(element.element, kAXPressAction as CFString) == .success
    usleep(300_000)
    if args.has("keep-front") == false { wasFrontmost?.activate() }
    emit(ok ? "pressed \(entry.path.joined(separator: " > "))"
            : "could not press \(entry.path.joined(separator: " > "))")
    exit(ok ? 0 : 1)

case "press":
    // Drives the real UI. It exists because a command that only ever runs inside the app is
    // a command nobody can test by hand, and the popup tier is the one route the shipped
    // audit cannot verify from a file.
    guard args.positional.count >= 3 else { fail("press needs a button description and an identifier") }
    guard MenuScanner.hasAccessibility else { fail("no Accessibility permission") }
    guard let xcode = targetXcode() else { fail("Xcode is not running") }
    let previous = NSWorkspace.shared.frontmostApplication
    xcode.activate()
    usleep(400_000)
    let pressed = PopupReader.press(button: args.positional[1],
                                    identifier: args.positional[2],
                                    pid: xcode.processIdentifier)
    usleep(300_000)
    previous?.activate()
    emit(pressed ? "pressed \(args.positional[2])" : "could not press \(args.positional[2])")
    exit(pressed ? 0 : 1)

case "builds":
    let builds = SnapshotStore().knownBuilds()
    if builds.isEmpty { emit("no Xcode builds recorded yet"); exit(0) }
    for (build, snapshot) in builds {
        // Unsettled means no scan with an editor focused yet: nothing is hidden or reported.
        let settled = snapshot.isSettled ? "settled" : "unsettled"
        emit("\(build)  Xcode \(snapshot.release.version)  \(snapshot.entries.count) items  \(settled)  last seen \(snapshot.capturedAt)")
    }

// MARK: - reference

case "reference":
    let (registry, keymap) = DefaultKeymap.build()
    let snapshot = snapshotSource(args, context: "xcmdr reference")
    let page = ReferencePage(registry: registry, keymap: keymap,
                             catalogue: MenuCatalogue(snapshot),
                             xcodeVersion: snapshot.release.version).render()
    if let path = args.value("output", "o") {
        do { try page.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { fail("cannot write \(path): \(error)") }
        err.write("wrote \(path)\n".data(using: .utf8)!)
    } else {
        emit(page)
    }

case "help", "--help", "-h":
    usage()

default:
    fail("unknown command '\(command)' — try `xcmdr help`")
}
