# Configuration

> For users, the same guide is on the website: [xcommander.dev/docs/configuration](https://xcommander.dev/docs/configuration). This page adds how it works inside.

XCommander works without any configuration. When you want to change a binding, add your own, or
pick another leader key, you write a small TOML file. Changes apply as soon as you save: no
rebuild and no relaunch.

## Where the files go

| File | Applies to |
|---|---|
| `~/.config/xcommander/config.toml` | Everywhere |
| `.xcommander.toml` in a project's root folder | That project only, layered on top of the global file |

Later files win, so a project file can be one line long. You can commit it to the project's
repository and share it with your team.

## An example

```toml
version = 1

[general]
leader = "⌃SPC"         # one of: ⌥RET (default), ⌘ESC, ⌃RET, ⌃SPC, ⌥SPC
panel-delay = 200       # milliseconds before the which-key panel appears (default 350)
sequence-timeout = 15   # seconds of inactivity before a sequence gives up (default 10)

[groups]
m = "build"             # what the which-key panel calls the m prefix

[keys]
"m z" = "make.clean"    # bind a key sequence to a command id
"f s" = "file.saveAll"

[unbind]
keys = ["q X"]          # remove bindings XCommander ships with
```

Every file must start with `version = 1`. If the format ever changes in a way that would make an
old file mean something different, the version goes up, and XCommander refuses a file it doesn't
understand rather than guessing.

## Key syntax

A sequence is keys separated by spaces, written the way the which-key panel shows them: `m m`,
`c d`, `f F`. Uppercase means Shift. Modifiers are `⌃ ⌥ ⇧ ⌘`. Keys without a character have
names: `ESC`, `SPC`, `TAB`, `RET`, `DEL`, arrows (`← → ↑ ↓`), `F1`–`F12`.

`ESC` can't be bound: it's how you cancel a sequence, including one your own config broke.

## Finding command ids

There are about 160 commands. To print all of them, with what they do and their default keys:

```sh
<path to XCommander.app>/Contents/MacOS/<executable> --print-reference
```

(With `swift run xcdev`, that's `~/Library/Caches/XCommander/XCommander.app/Contents/MacOS/Companion`.)

The commands themselves are defined in `Sources/XCommanderCore/DefaultKeymap.swift`.

The website's [command reference](https://xcommander.dev/docs/commands) is generated from that
file. After changing the keymap, regenerate it and commit the page in the website repository:

```sh
swift run xcmdr reference --snapshot ~/.config/xcommander/xcode/<build>.json \
    -o ../Website/user/pages/02.docs/03.commands/docs.md
```

`--snapshot` points at the menus your own Xcode recorded (`swift run xcmdr builds` lists them), so
the reference shows Xcode's menu paths as they really are. Without it, `xcmdr` reads the running
Xcode.

## When a file has a mistake

XCommander never applies half a file. It parses and checks the whole thing into a new keymap,
and only swaps it in if it's valid. If you save a file with a typo, you keep working with the
last good keymap, and the problem is reported:

- in the Settings window, which shows what the last load said;
- from Terminal, with `--check`, which runs the exact code the app uses:

```sh
<path to XCommander.app>/Contents/MacOS/<executable> --check ~/.config/xcommander/config.toml
```

It exits non-zero on errors, and suggests the closest match for a mistyped command id.

Sections that exist in the format but aren't built yet (`[commands]` for macros, `[layouts]` for
saved pane arrangements) are announced and ignored, and the rest of the file still loads.

## How it works

The pipeline is three pure functions in `Sources/XCommanderCore/Config/`:

1. **Parse** (`TOML.swift`): text into entries with line numbers. XCommander has its own small
   TOML reader, so it has no dependencies.
2. **Decode** (`ConfigDocument.swift`): entries into one document per file, with diagnostics.
3. **Resolve** (`ConfigResolver.swift`): documents plus the shipped keymap into one keymap.

`ConfigStore.swift` in the app is the part that touches the disk: it finds the files, watches
them with a file-system event source, waits for an editor's burst of writes to settle, and keeps
the last good result. Because the interesting part is pure, it's covered by
`Tests/XCommanderCoreTests/ConfigTests.swift` without ever touching a file.
