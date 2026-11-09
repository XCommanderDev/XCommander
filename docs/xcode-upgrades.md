# Surviving Xcode upgrades

Apple ships a new Xcode every year and betas in between, and XCommander depends on things Apple
never promised to keep stable: menu items, their shortcuts, the layout of Xcode's window. This
page explains how the app absorbs most changes on its own, and how you can help when a new
Xcode comes out. The code is in `Sources/XCommanderCore/MenuCatalogue.swift`, `Sources/XcodeMenus/` and
`Sources/xcmdr/`.

## The idea: name commands by their action

A menu item's `AXIdentifier` is the Objective-C action behind it, like
`buildActiveRunContext:`. When Apple renames "Build" or moves it to another menu, the action
usually stays the same. So every shipped command names its menu item with a `MenuRef` built from
the identifier, not from a title or a path:

```swift
.menu("make.build", "build", MenuRef("buildActiveRunContext:")),
```

When Apple does rename an action, the old binding doesn't have to break: a `MenuRef` can list
**alternates**, and the first one this Xcode has wins. Xcode 27 renamed four items XCommander
binds and moved none of them, and identifiers absorbed all four.

## What happens on a user's machine

Nothing here needs a new XCommander release.

**1. One rule picks the Xcode.** Every copy of Xcode has the bundle ID `com.apple.dt.Xcode`, so
with a release and a beta both open there are two candidates. `XcodeTarget.choose` decides, and
the app and `xcmdr` share it: the frontmost Xcode, otherwise the one that was in front last,
otherwise the most recently launched.

**2. Every scan is remembered per Xcode build.** Each time you switch to Xcode, the app re-reads
its menus in the background and merges them into a snapshot for that exact build, in
`~/.config/xcommander/xcode/<build>.json`. Snapshots of one build accumulate across contexts
(menus differ with an editor focused, while debugging…). Different builds never merge.

**3. Nothing is decided until the build has *settled*.** After an update, Xcode reopens on its
Welcome window, where the menu bar is much smaller: on Xcode 27.2, 509 items instead of 752, and
27 of the 115 shipped bindings missing. Treating that as "Apple removed 27 commands" would be
wrong. So a build counts as **settled** only once one scan was taken with a source editor
focused. Before that, nothing is hidden and nothing is reported.

**4. Then the app compares builds.** Once the new build settles, it's compared with the previous
settled build (`CatalogueDiff`). Renames and moves are reported as information. A command that's
really gone is hidden from the which-key panel, so it never shows a key that can't work. Titles
that only differ by context (an open file's name, a toggle showing its other state, the window
list) are ignored.

**5. The user gets a report, and only sometimes a notice.** A Markdown report is written to
`~/.config/xcommander/xcode/CHANGES.md` whenever there's anything worth reading. The menu bar
only shows a line when the user **lost a key they had bound**, or a menu item now collides with
their leader key. Announcing every rename would train people to ignore the one line that
matters.

**6. Old XCommander, new files.** Snapshots carry a schema version. An older XCommander refuses
to read, or overwrite, a snapshot written by a newer one.

## Support policy

XCommander supports **Xcode 27 and later**, and nothing earlier: older versions are never
tested, so they're never claimed. There's no upper limit: a beta nobody has tested is expected to
work on day one, and usually does, because of the identifiers. The floor is
`XcodeRelease.minimumMajor`, and the Xcode 27 capture stays in `Fixtures/` as the baseline.

## The tool: `xcmdr`

`xcmdr` is a command-line tool that uses exactly the same menu scanner as the app, so what it
reports is what ships. Run it with `swift run xcmdr <command>`; `swift run xcmdr help` lists
everything.

| Command | What it does |
|---|---|
| **Look and report** | |
| `xcmdr doctor` | Checks this machine: permission, which Xcode, window assumptions, leader keys |
| `xcmdr list --under "Product"` | Browses a menu |
| `xcmdr resolve IDENTIFIER` | Finds where an action lives |
| `xcmdr run IDENTIFIER` | Presses one menu item, exactly as the app would |
| `xcmdr builds` | Lists the Xcode builds recorded on this machine, settled or not |
| **Capture and check an Xcode** | |
| `xcmdr snapshot -o FILE -c NOTE` | Captures the running Xcode's menus, with a note about what was on screen |
| `xcmdr merge A.json B.json -o OUT` | Merges two captures of the same build |
| `xcmdr audit [--snapshot FILE]` | Checks every shipped binding resolves; exit code 0 means all good |
| `xcmdr diff OLD.json NEW.json` | Shows what Apple changed between two builds |
| `xcmdr popups` | Checks the toolbar popups (this opens them on screen) |

With two Xcodes running, add `--xcode /Applications/Xcode-beta.app` (or a process ID).

**Captures are safe to share.** Xcode's menus also list your recent projects, your devices and
simulators, your open windows and your schemes. `xcmdr` replaces those names with placeholders
(`Recent item 1`, `Run destination 3`…) in every file it writes, so a capture says which commands
your Xcode has and nothing about you. The snapshots the app keeps for itself in
`~/.config/xcommander/xcode/` are never shared and aren't redacted: send an `xcmdr` capture
instead.

## Helping with an Xcode beta

If you run an Xcode beta, you can help XCommander support it before I've installed it myself.

**1. Look at it.** Keep your current Xcode, and install the beta beside it (`Xcode-beta.app`).
Then:

```sh
swift run xcmdr doctor --xcode /Applications/Xcode-beta.app
```

The window assumptions and leader keys sections are the ones that matter.

**2. Capture it.** One scan is one context, because Xcode's menus change with what's on screen,
so take three:

```sh
swift run xcmdr snapshot --xcode … -o /tmp/editor.json -c "source editor focused, navigator hidden"
swift run xcmdr snapshot --xcode … -o /tmp/rich.json -c "navigator, debug area and inspector open"
swift run xcmdr snapshot --xcode … -o /tmp/paused.json -c "running under the debugger and paused"
swift run xcmdr merge /tmp/editor.json /tmp/rich.json -o Fixtures/Xcode-<build>.json
swift run xcmdr merge Fixtures/Xcode-<build>.json /tmp/paused.json -o Fixtures/Xcode-<build>.json
```

**3. Compare it.**

```sh
swift run xcmdr audit --snapshot Fixtures/Xcode-<build>.json
swift run xcmdr diff Fixtures/Xcode-27A266.json Fixtures/Xcode-<build>.json
```

Then open a pull request with the merged fixture and the `audit` and `diff` output, or attach
them to an issue. If the audit found something, a fix usually means adding the new identifier to
the command's `MenuRef` alternates; the tests will tell you whether it holds.
