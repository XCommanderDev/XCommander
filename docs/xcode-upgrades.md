# Surviving Xcode upgrades

Apple ships a new Xcode every year and betas in between, and XCommander depends on things Apple
never promised to keep stable: menu items, their shortcuts, the layout of Xcode's window. This
page explains how the app absorbs most changes on its own, and what a maintainer does for the
rest. The code is in `Sources/XCommanderCore/MenuCatalogue.swift`, `Sources/XcodeMenus/` and
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

## The maintainer's tool: `xcmdr`

`xcmdr` is a command-line tool that uses exactly the same menu scanner as the app, so an audit
checks what actually ships. Run it with `swift run xcmdr <command>`.

| Command | What it does |
|---|---|
| `xcmdr doctor` | Checks this machine: permission, which Xcode, window assumptions, leader keys |
| `xcmdr snapshot -o FILE -c NOTE` | Captures the running Xcode's menus, with a note about what was on screen |
| `xcmdr merge A.json B.json -o OUT` | Merges two captures of the same build |
| `xcmdr audit [--snapshot FILE]` | Checks every shipped binding resolves; exit code 0 means all good |
| `xcmdr diff OLD.json NEW.json` | Shows what Apple changed between two builds |
| `xcmdr list --under "Product"` | Browses a menu |
| `xcmdr resolve IDENTIFIER` | Finds where an action lives |
| `xcmdr popups` | Checks the toolbar popups (this opens them on screen) |
| `xcmdr builds` | Lists the Xcode builds recorded on this machine, settled or not |

With two Xcodes running, add `--xcode /Applications/Xcode-beta.app` (or a process ID).

## Checklist for a new Xcode

When Apple ships a beta or a release:

**1. Look at it**

- [ ] Install it next to the current Xcode (`Xcode-beta.app`). Don't replace the current one.
- [ ] `xcmdr doctor --xcode /Applications/Xcode-beta.app`. Read the window assumptions and the
      leader keys sections.

**2. Capture it.** One scan is one context, so take three:

- [ ] Source editor focused, navigator hidden:
      `xcmdr snapshot --xcode … -o /tmp/editor.json -c "source editor focused, navigator hidden"`
- [ ] Navigator, debug area and inspector open:
      `xcmdr snapshot --xcode … -o /tmp/rich.json -c "navigator, debug area and inspector open"`
- [ ] Running under the debugger, paused:
      `xcmdr snapshot --xcode … -o /tmp/paused.json -c "running under the debugger and paused"`
- [ ] `xcmdr merge /tmp/editor.json /tmp/rich.json -o Fixtures/Xcode-<build>.json`
- [ ] `xcmdr merge Fixtures/Xcode-<build>.json /tmp/paused.json -o Fixtures/Xcode-<build>.json`

**3. Compare it**

- [ ] `xcmdr audit --snapshot Fixtures/Xcode-<build>.json`
- [ ] `xcmdr diff Fixtures/Xcode-<previous>.json Fixtures/Xcode-<build>.json`
- [ ] `xcmdr popups --xcode …`

**4. Rehearse it with the app.** Fixtures prove the code does what it says; only the real app
shows whether it's true.

- [ ] Copy the previous build's snapshot into `~/.config/xcommander/xcode/`, quit Xcode and
      reopen it (it comes back on the Welcome window, like after an update). `xcmdr builds`
      should say **unsettled**, and there should be no `CHANGES.md`.
- [ ] Open a project, focus a source file, switch away and back. It should now be **settled**,
      with `CHANGES.md` written.
- [ ] Press the leader right after switching to Xcode: the panel should appear at the usual
      speed.
- [ ] With the panel up, drag Xcode's window: the panel follows, including after a relaunch.

**5. Fix forward**

- [ ] A renamed action: add the new identifier to the command's `MenuRef` alternates.
- [ ] A command now on a leader's chord: update `LeaderChoice.shadows` **and** its note.
- [ ] A changed window landmark: update `XcodeAXSchema`.
- [ ] A command moved into a toolbar popup: make it a `PopupMenuRef`.
- [ ] Never delete a binding for a command that a supported Xcode still has.

**6. Pin it**

- [ ] Add a test that loads the new fixture, like the existing Xcode 27 one, and run the
      shipped-binding and leader tests against it.
- [ ] `swift test` passes.

**7. On a new major version only**

- [ ] Keep the previous fixtures and their tests. The floor stays at Xcode 27.
- [ ] Mention the new version in the README.

## Helping as a contributor

You don't need to be the maintainer for steps 1–3. If you run an Xcode beta, capturing its menus
and opening a pull request with the merged fixture and the `audit` and `diff` output lets
XCommander support a beta before I've installed it.
