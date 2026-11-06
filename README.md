# XCommander

**A leader key for Xcode**, in the spirit of [Spacemacs](https://www.spacemacs.org/) and [Doom Emacs](https://github.com/doomemacs/doomemacs).

Press <kbd>⌥</kbd><kbd>↩</kbd> in Xcode and a which-key panel shows what comes next: a mnemonic tree of commands for menus, panes, navigators and buffers.

> [!IMPORTANT]
> XCommander is a vision, not a product yet. There is nothing to download and nothing works end to end. I'm building it in the open, one piece at a time.

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
- **`XCommanderCore`**: a Swift package holding the logic (status, keymap, key sequences) with no UI, so it can be tested with Swift Testing.

An app that uses an event tap can't be sandboxed, so XCommander won't be on the Mac App Store. It will be distributed directly.

## Status

Early days. Today it has:

- [x] Menu bar item with a status
- [x] Accessibility permission request and polling
- [ ] Event tap and leader key
- [ ] Which-key panel
- [ ] Running Xcode menu commands through Accessibility
- [ ] Configurable keymap

## Building

Requires a recent macOS and Xcode. Open `XCommander/XCommander.xcodeproj` and run the `XCommander` scheme. On first launch, grant Accessibility permission in System Settings → Privacy & Security → Accessibility.

## Follow along

- Build log: [xcommander.dev/weblog](https://xcommander.dev/weblog/) ([RSS](https://xcommander.dev/weblog.rss))
- Mastodon: [@xcommander@mastodon.social](https://mastodon.social/@xcommander)

Issues and ideas are welcome. Since this is a personal tool first, I may say no to features that pull it away from what I need.

---

Xcode is a trademark of Apple Inc. XCommander is an independent project, not affiliated with Apple.
