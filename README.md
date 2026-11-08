# XCommander

**A leader key for Xcode**, in the spirit of [Spacemacs](https://www.spacemacs.org/) and [Doom Emacs](https://github.com/doomemacs/doomemacs).

Press <kbd>⌥</kbd><kbd>↩</kbd> in Xcode and a which-key panel shows what comes next: a mnemonic tree of commands for menus, panes, navigators and buffers.

> [!IMPORTANT]
> XCommander is a work in progress, not a product yet. It works, I use it every day, and it still has rough edges. There is nothing to download: you build it yourself for now.

## Why

I write Swift in Doom Emacs, and I want that same keyboard flow in Xcode without giving up Xcode. So I'm building the tool I want for myself. It's free and open source in case it helps someone else too.

I don't have the full design worked out. I find things out as I build: what macOS allows, what Xcode exposes, what feels right under the fingers. When I learn something, I write about it in the [build log](https://xcommander.dev/weblog/).

## How it works (for now)

XCommander doesn't plug into Xcode. Since Xcode 8, in-process plugins are gone, and Source Editor Extensions only see text. So XCommander sits outside Xcode and talks to it the way an assistive app would:

```
 keyboard ──▶ Event tap ──▶ Keymap ──▶ Accessibility API ──▶ Xcode
              (spots ⌥↩      (resolves     (reads and presses
               when Xcode     the key       Xcode's menus,
               is in front)   sequence)     panes and buttons)
                                  │
                                  ▼
                           which-key panel
```

- **Menu bar app** (AppKit): no Dock icon, just a status item that shows whether XCommander is ready, waiting for Xcode, or needs permission.
- **Event tap** (Core Graphics): watches the keyboard. Only while Xcode is in front, and only after the leader key, does it take over keys.
- **Accessibility API**: reads Xcode's menu bar and UI live, and triggers commands through it. This is why the app asks for Accessibility permission.
- **`XCommanderCore`**: the logic (keymap, key sequences, fuzzy matching, pane geometry, config) with no UI, so it's covered by Swift Testing without a screen.

[ARCHITECTURE.md](ARCHITECTURE.md) explains how it all fits together, and [docs/](docs/README.md) has a guide for each part, written for iOS developers who are new to AppKit, like I was.

An app that uses an event tap can't be sandboxed, so XCommander won't be on the Mac App Store. It will be distributed directly.

## Xcode versions

Apple ships a new Xcode every year, with betas in between, and XCommander has to keep working when Xcode changes under it. The plan:

- **Commands are found by the action behind a menu item, not by its title or position.** A renamed or moved menu item keeps working, and a beta nobody has tested works on day one.
- **XCommander supports Xcode 27 and later.** Earlier versions aren't tested, so they aren't supported. There is no upper limit.
- **When a new Xcode removes a command you had bound, its key is hidden** rather than left doing nothing, and XCommander writes a short report saying what changed.
- **A release and a beta can run side by side.** XCommander talks to the one in front.

All of this is built. [docs/xcode-upgrades.md](docs/xcode-upgrades.md) explains how, and has the checklist I follow when Apple ships a new Xcode.

## Status

What works today:

- [x] Leader key and which-key panel that follows Xcode's window
- [x] About 160 commands in a mnemonic tree: build and run, navigation, code, git, debug, navigators, inspectors
- [x] Command palette over every Xcode menu item, and pickers for files, open editors, symbols, schemes and destinations
- [x] Project-wide search with ripgrep, with a syntax-coloured preview
- [x] Pane control Xcode doesn't have: move focus by direction, swap, send, balance, zoom
- [x] Text transforms on the selection (align, sort, join, change case…), undoable with ⌘Z
- [x] A config file with live reload
- [x] Keeps working across Xcode updates, with a report when Xcode changes something you use

Still to do before a first release: daily use and bug fixing, then signing, notarization and updates.

The prototype was built in its own repository under the working name Autographe, and its history was merged into this one in November 2026.

## Building

Requires macOS 14 or later and Xcode 27 or later. Project search needs [ripgrep](https://github.com/BurntSushi/ripgrep) (`brew install ripgrep`).

1. Open `XCommander.xcodeproj`.
2. To sign with your own Apple account, create `Config/Signing.local.xcconfig` (git ignores it) with your Team ID and a bundle ID prefix of your own:

   ```
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   BUNDLE_ID_PREFIX = com.yourname
   ```

3. Run the `XCommander` scheme. On first launch, grant Accessibility permission in System Settings → Privacy & Security → Accessibility.
4. In Xcode, press <kbd>⌥</kbd><kbd>↩</kbd> and wait a moment for the panel.

From Terminal, `swift run xcdev run` builds, signs and launches the app, and `swift test` runs the tests. [docs/permissions-and-signing.md](docs/permissions-and-signing.md) explains both, and [CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## Official builds

Official builds are published on this repository's [Releases](https://github.com/XCommanderDev/XCommander/releases) page and linked from [xcommander.dev](https://xcommander.dev). They're built by GitHub Actions from a tagged commit, signed with my Developer ID and notarized by Apple, and they update themselves with [Sparkle](https://sparkle-project.org). Builds from anywhere else are not the official app. For now they're early alphas: expect bugs.

## Follow along

- Build log: [xcommander.dev/weblog](https://xcommander.dev/weblog/) ([RSS](https://xcommander.dev/weblog.rss))
- Mastodon: [@xcommander@mastodon.social](https://mastodon.social/@xcommander)

Issues and ideas are welcome. Since this is a personal tool first, I may say no to features that pull it away from what I need. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

If you run Xcode betas, you can help a lot: a capture of a new beta's menus with `xcmdr` lets me support it before I've installed it myself. See [docs/xcode-upgrades.md](docs/xcode-upgrades.md).

## License

Copyright © 2026 Wassim Mansouri.

XCommander is free software: you can redistribute it and/or modify it under the terms of the [GNU General Public License v3](LICENSE).

The XCommander name and icon are not covered by the license. Forks are welcome under a different name and icon; see [TRADEMARKS.md](TRADEMARKS.md).

---

Xcode is a trademark of Apple Inc. XCommander is an independent project, not affiliated with Apple.
