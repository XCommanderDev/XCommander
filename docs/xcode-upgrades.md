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

## Three Xcodes on one Mac, step by step

Say you have the release (`Xcode.app`), the second beta (`Xcode-beta.app`) and the first beta
(`Xcode-beta-1.app`), and one copy of XCommander.

1. You bring the second beta forward. `XcodeTarget.choose` picks it by process, because it's the
   one in front.
2. XCommander reads its menus again in the background. It keeps one index per running Xcode, so
   switching back to the release later costs nothing.
3. `⌥↩ m m` looks for `buildActiveRunContext:` in **that** Xcode's menus and presses it. Nothing
   in that lookup knows which version it's talking to; the running Xcode answers "is it here?"
   for itself.
4. The scan is merged into the second beta's own snapshot. Three builds, three files, never
   merged together.
5. If the second beta dropped a command you have a key for, nothing is pressed. Once that build
   has settled, the key is hidden, **only while the second beta is in front**. In the release
   and the first beta it still shows and still works.
6. When the second beta first settles, it's compared with the build before it and `CHANGES.md`
   is written. The lost key is listed first, and the menu bar says one line about it.

### The keymap and the snapshots are different things

- **The keymap** says which key runs which command: the shipped table plus your `config.toml`.
  It's never learnt from Xcode.
- **The snapshots** say what each Xcode build has been seen to offer, learnt from Xcode, one file
  per build.

The snapshots are kept even though the menus are read every time, for two reasons. One read only
shows what was on screen, so only the accumulated snapshot can tell "not available right now"
from "this Xcode doesn't have it". And after an update the old Xcode is gone, so its snapshot is
the only thing left to compare with.

## Your config and Xcode changes

Your `config.toml` names XCommander's command ids, like `make.build`, and nothing else. It never
names Xcode's menu titles, paths or identifiers. The link from `make.build` to Xcode's menu
lives in `DefaultKeymap.swift`. So:

| Apple… | Your config |
|---|---|
| renames or moves a menu item | Nothing to do: the identifier still matches |
| renames the action itself | Nothing to change. The fix is a new alternate on the command, and it reaches you in an update. Until then the key does nothing on that Xcode, and you can't point it at the new identifier yourself; you can only put another command on it |
| removes a command | Your binding stays. The key is hidden only while an Xcode without the command is in front |

The report reads **your** keymap, not the shipped one: a key you unbound isn't reported as lost,
and a key you added is.

## One XCommander for every Xcode

There's no XCommander release per Xcode, and no "XCommander for the Xcode beta". One build serves
every Xcode from 27 up, the release and its betas at the same time, and a fix for a new Xcode
only adds names, so it can't break an older one. XCommander's version numbers follow its own
features. A prerelease (`1.1.0-beta.1`) is a prerelease of XCommander, not of Xcode.

Keep **one copy** installed. Two copies would share the bundle ID, so they'd share one
Accessibility grant, one update channel and one `~/.config/xcommander/` folder, and both would
watch for the same leader key. To try a newer build, either install a prerelease (after that,
updates offer you prereleases and finals), or build from source and quit the installed copy while
it runs.

## Every case, and what to do

| Situation | What XCommander does | What you see | If it goes wrong |
|---|---|---|---|
| Several Xcodes, any number running | Acts on the one in front; otherwise the one last in front; otherwise the most recently launched | Keys act on the Xcode you're using | Report it: one rule decides this everywhere |
| Xcode older than 27 | Below the floor | A message at first run and in the menu bar | Update Xcode |
| Xcode relaunches after an update | Drops the old process's menus and re-attaches to the window | Nothing to do | `⌥↩ q r` |
| Updated Xcode reopens on its Welcome window | The build isn't settled, so nothing is hidden or reported | Every key still shows | — |
| You open a project and click into a file | The build settles, is compared with the previous one, and `CHANGES.md` is written if anything changed | A report; a menu bar line only if you lost a key or your leader now hides an Xcode shortcut | No report after a few sessions: report it with your Xcode version |
| Apple renamed or moved a command | Still found by its identifier | The key works; maybe listed under titles that changed | — |
| A command only shows in some situations (debugging, editor focused) | Snapshots accumulate, so "missing now" isn't "removed" | The key shows; pressing it elsewhere does nothing | — |
| Apple removed a command you use | Nothing is pressed; once settled, the key is hidden on that build | The key disappears on that Xcode only; listed first in `CHANGES.md` | Nothing to fix. Reuse the key for another command if you like |
| Apple renamed the action behind a command | Like a removal, until an update adds the new name | Same as a removal | Wait for the update, or **Report a Bug…** |
| Apple moved a command into a toolbar popup | Found only once XCommander knows it's a popup | The key may stop working | Report it |
| Apple put a shortcut on your leader key | Your leader hides it while Xcode is in front | A menu bar line and a note in `CHANGES.md` | Choose another leader in Settings or `config.toml` |
| Apple changed the window's layout | After a pane command fails in a project window, XCommander checks its assumptions | A "may have changed" note and one menu bar line | Report it |
| An older XCommander installed after a newer one | Refuses snapshots from the newer one rather than overwriting them; hides nothing | Every key shows; no reports | Reinstall the newer one, or delete `~/.config/xcommander/xcode/` |
| A typo in `config.toml` | The whole file is checked first; nearest match suggested | The last good keymap stays; Settings shows the error | Fix and save |
| `~/.config/xcommander/xcode/` deleted or damaged | Rebuilt from Xcode | Nothing hidden until a build settles again | You lose the baseline, so the next update writes no report |

If nothing above fits: `⌥↩ q r` re-reads the menus and reloads your config; then quit and reopen
XCommander and Xcode; then delete `~/.config/xcommander/xcode/`; then use **Report a Bug…** in
the menu and attach `CHANGES.md` if there is one. Contributors can add `xcmdr doctor`, and
`⌥↩ h c`, which checks every binding against the Xcode in front and writes the result to the log
(`swift run xcdev logs`).

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
