# Debugging

When something doesn't work, it's almost always one of four things: permission, the event tap,
what XCommander can see in Xcode, or a bug in our logic. Here's how I narrow it down.

## First: what does the menu bar icon say?

| Icon | Meaning |
|---|---|
| The hat, full strength | Ready: Xcode is in front and the leader is live |
| The hat, dimmed | Running, but Xcode isn't in front, or XCommander is switched off |
| ⚠️ Warning triangle | Accessibility permission is missing |
| 🔒 Padlock | Another app has turned on secure input (a password field, some terminals). No app can see keys until it's released. |

The tooltip and the first line of the menu say the same thing in words.

## Read the logs

XCommander logs with `os.Logger` under the subsystem `dev.xcommander.XCommander`, with one
category per area: `app`, `tap`, `menus`, `executor`, `panes`, `navigator`, `config`, `search`,
`index`, `preview`, `tracker`, `open`, `updates`.

```sh
swift run xcdev logs                   # everything, live, including debug messages

log stream --predicate 'subsystem == "dev.xcommander.XCommander" AND category == "executor"' --level debug

log show --last 10m --predicate 'subsystem == "dev.xcommander.XCommander"'   # what already happened
```

`.debug` messages only appear in a live stream. `.notice` and above are kept, so `log show` can
read them afterwards. If a value shows up as `<private>`, the log line forgot
`privacy: .public`.

Console.app shows the same thing with a UI: filter on the subsystem.

Every command that runs logs how it ran (`via menu Product > Build` or `via ⌘B`), and every
failure logs why. That's usually the fastest way to see where a key went.

## Ask the machine: `xcmdr doctor`

```sh
swift run xcmdr doctor
```

It checks permission, which Xcode XCommander would talk to, whether Xcode's window still looks
the way the app expects, and whether the leader keys collide with any of Xcode's shortcuts. Run
it first when something worked yesterday and doesn't today, especially after an Xcode update.

Other `xcmdr` commands help with a specific binding:

```sh
swift run xcmdr audit                          # does every shipped binding resolve in this Xcode?
swift run xcmdr resolve buildActiveRunContext: # where is this action in the menus?
swift run xcmdr list --under "Editor"          # what's in this menu right now?
swift run xcmdr run buildActiveRunContext:     # press it, exactly as the app would
```

Remember that Xcode's menus depend on what's on screen. A command can be missing simply because
no editor is focused.

## Look at Xcode: the Accessibility Inspector

Xcode menu → Open Developer Tool → **Accessibility Inspector**. Point it at the thing in Xcode
that XCommander can't find. It shows the element's role, identifier, attributes and actions:
exactly what our code sees. If the inspector can't see it, XCommander can't either.

## Common problems

**Nothing happens when I press the leader.**
1. Is Xcode really the frontmost app? XCommander only takes keys while it is.
2. Check the menu bar icon (above).
3. Permission looks granted but nothing works: after a rebuild with a different signature,
   macOS can show the switch as on while refusing the new build. Remove XCommander from System
   Settings → Privacy & Security → Accessibility, relaunch, and grant it again. See
   [Permissions, signing and the dev loop](permissions-and-signing.md).
4. Are two copies running (one from Xcode, one from `swift run xcdev`)? Quit one.

**The panel shows, but a command does nothing (or beeps).**
The log says why (`executor` category). Usually the menu item is disabled in the current context,
or this Xcode doesn't have it. `xcmdr resolve <identifier>` tells you which.

**A pane command fails.**
The app checks whether Xcode's window still matches its assumptions and logs the result. If
Xcode changed its window layout, see [Surviving Xcode upgrades](xcode-upgrades.md).

**Keys arrive late.**
Something is blocking the main thread, which the event tap shares. Look for slow work added to
the main actor, especially Accessibility calls in loops.

**The search picker finds nothing.**
Project search uses ripgrep. Install it with `brew install ripgrep`. The log says
`ripgrep not found` if it's missing.

**Symbol pickers are empty.**
They read the index Xcode builds for a project. Build the project once in Xcode, and check that
`xcode-select -p` points at the Xcode you use.

## Debugging with breakpoints

Run the **XCommander** scheme from Xcode and set breakpoints as usual. One catch: **don't put a
breakpoint inside the event tap callback or anything it calls synchronously** (`handleKey`,
`KeymapSession.press`). While you're stopped there, the tap doesn't answer, macOS disables it,
and keyboard input to every app can stall until you continue. Put the breakpoint in `run(_:)` or
the executor instead, or log.

Pure logic in `XCommanderCore` is much easier to debug with a unit test: write a test that
reproduces the bug, then fix it. Most of the existing tests started that way.
