# Architecture

This is the map I wish I'd had when I started. It explains how XCommander is put together,
where each piece lives, and why it's shaped the way it is. If you're new to the codebase, read
this first, then pick a guide from [`docs/`](docs/README.md) for the area you want to work on.

## The one-paragraph version

XCommander is a menu-bar app that sits **outside** Xcode. It watches the keyboard with an
**event tap**. While Xcode is in front and you press the leader (<kbd>⌥</kbd><kbd>↩</kbd> by
default), it takes over the next few keys, walks a **keymap tree**, and shows a **which-key
panel** after a short pause. When a sequence reaches a command, it runs it by **pressing one of
Xcode's own menu items through the Accessibility API**, or by doing something Xcode can't do
itself (pickers, text transforms, pane moves). Nothing is injected into Xcode. XCommander only
does what an assistive app is allowed to do.

## Why it lives outside Xcode

Xcode has had no plugin system since Xcode 8, and Source Editor Extensions only ever saw the
text of one file. A tool that changes how Xcode *feels* (keys, panes, navigation) has to drive
it from outside, the way VoiceOver or Keyboard Maestro do. macOS gives an outside app three ways
in:

| Route | What it reaches | Used for |
|---|---|---|
| **Event taps** (Core Graphics) | Every keystroke, before the app gets it | Spotting the leader and taking over keys |
| **Accessibility API** (`AXUIElement`) | Xcode's menus, windows, panes, text | Reading and pressing menu items, moving between panes, editing the selection |
| Apple Events | Only what an app chooses to script | Not used: Xcode's scripting dictionary doesn't cover what we need |

Both routes need the user to grant **Accessibility** permission, and an event tap can't run in
the App Sandbox, so XCommander can never be on the Mac App Store.

## The targets

The code is one Swift package (`Package.swift`) plus an XcodeGen project (`project.yml`) that
wraps the app target for Xcode.

```
Sources/
├── XCommanderCore/   Pure logic. No AppKit, no Accessibility. Fully unit-tested.
├── XcodeMenus/       Walks Xcode's menu bar over Accessibility. Shared by the app and xcmdr.
├── Companion/        The app itself: AppKit, the event tap, windows, Accessibility calls.
├── xcmdr/            A command-line maintenance tool (scan, audit and diff Xcode's menus).
├── CIndexStore/      C type declarations for Xcode's index store library. No code linked.
└── CSourceKit/       C type declarations for sourcekitd. No code linked.
Tests/
├── XCommanderCoreTests/
└── XcodeMenusTests/
Fixtures/             A recorded scan of Xcode 27's menus, used by the tests.
```

**The most important rule in the codebase: `XCommanderCore` knows nothing about AppKit.** The
keymap, the session state machine, the fuzzy matcher, pane geometry, config parsing, the preview
model: all of it is plain Swift, so `swift test` runs about 360 tests headless in under a second.
The AppKit side (`Companion`) is kept thin. It translates between the real world (keycodes,
`AXUIElement`s, windows) and Core's value types, and that's where the hard-to-test code lives.

When you add something, ask: *does this need a window, an event or an Accessibility call?* If
not, it belongs in Core, with tests.

## The keystroke path

This is the heart of the app. Follow it once in the code and everything else makes sense.

```
 key press
    │
    ▼
 EventTap (Companion/EventTap.swift)
    │  C callback on the main run loop. Extracts keycode + modifier flags.
    ▼
 AppDelegate.handleKey (Companion/AppDelegate.swift)
    │  Is XCommander enabled? Is Xcode in front? If not → pass the key through.
    ▼
 EventBridge.keyEvent (Companion/EventBridge.swift)
    │  keycode + flags → KeyEvent, using the current keyboard layout
    │  (KeyboardLayout.swift + Core's KeyIdentity).
    ▼
 Is a picker open?  ──yes──▶ PickerSession.press (Core/Picker.swift) → PickerOverlay
    │ no
    ▼
 KeymapSession.press (Core/KeymapSession.swift)
    │  Returns one of:
    ├─ .passThrough  → not ours, Xcode gets the key
    ├─ .awaiting     → swallow; OverlayController shows the which-key panel after ~350 ms
    ├─ .cancelled    → swallow; hide the panel (Esc, unbound key, timeout)
    └─ .fired(id)    → swallow; run the command on the next run loop turn
                          │
                          ▼
                   CommandRegistry → Command (Core/Command.swift)
                          │
                          ▼
                   CommandExecutor.run (Companion/CommandExecutor.swift)
                          │  depending on the command's action:
                          ├─ .menu      → press Xcode's menu item over Accessibility
                          ├─ .shortcut  → post a synthetic key event
                          ├─ .popupMenu → open a toolbar popup and press an item in it
                          ├─ .picker    → open a picker (commands, files, symbols, search…)
                          ├─ .transform → rewrite the editor's selection in place
                          ├─ .pane      → PaneController: focus/resize/swap editor panes
                          └─ .focus     → AreaController: focus navigator/debug area
```

Three things to notice:

1. **The tap callback must be fast.** It runs on every key you type in every app. It decides
   swallow-or-pass using in-memory state only and returns in microseconds. If it's slow, macOS
   disables the tap. That's why commands run on the *next* run-loop turn
   (`DispatchQueue.main.async`) and never inside the callback.
2. **The session is pure.** `KeymapSession` is a struct in Core with no timers and no UI. It's
   given a key and returns a decision. The timeout and the panel delay are managed by the app
   around it. That's why the whole modal engine is unit-tested.
3. **Commands name menu items by their action, not their title.** A binding says "the menu item
   whose action is `buildActiveRunContext:`", not "Product > Build". Titles change between Xcode
   versions and languages; the action (exposed as `AXIdentifier`) doesn't. See
   [Surviving Xcode upgrades](docs/xcode-upgrades.md).

## Who owns what

`AppDelegate` is the hub. It creates everything in `applicationDidFinishLaunching` and wires the
pieces together with closures. None of the controllers know about each other.

| Piece | File | Job |
|---|---|---|
| `AppDelegate` | `Companion/AppDelegate.swift` | Creates and connects everything. Owns the keystroke path, the pickers' data, permission and lifecycle. |
| `EventTap` | `Companion/EventTap.swift` | Installs the `CGEventTap`, re-enables it if macOS disables it, polls for secure input. |
| `AccessibilityXcodeContext` | `Companion/XcodeContext.swift` | **Everything we ask Xcode**, behind the `XcodeContext` protocol: which Xcode, its window frame, menu items, the selection, editor tabs. |
| `CommandExecutor` | `Companion/CommandExecutor.swift` | Turns a `Command` into an action against Xcode. |
| `OverlayController` | `Companion/OverlayController.swift` | The which-key panel: a borderless, non-activating `NSPanel` pinned to Xcode's window. |
| `PickerOverlay` | `Companion/PickerOverlay.swift` | The picker window (query line, ranked list, optional preview pane). Never takes focus. |
| `WindowTracker` | `Companion/WindowTracker.swift` | `AXObserver` on Xcode's window, so the panels follow it when it moves or resizes. |
| `PaneController`, `AreaController` | `Companion/` | Editor panes, navigator, inspector and debug area, over Accessibility. |
| `MenuBarController` | `Companion/MenuBarController.swift` | The status item and its menu. |
| `SettingsWindow`, `FirstRunWindow` | `Companion/` | SwiftUI windows hosted in AppKit. |
| `ConfigStore` | `Companion/ConfigStore.swift` | Finds, watches and reloads `config.toml`, keeps the last good result. |
| `FileIndex`, `DocumentHistory`, `ProjectSearch`, `SymbolIndex`, `PreviewLoader` | `Companion/` | Data for the pickers: project files, recent files, ripgrep, Xcode's index store, the preview pane. |
| `KeymapSession`, `Keymap`, `CommandRegistry`, `DefaultKeymap` | `XCommanderCore/` | The modal engine and the shipped bindings. |
| `MenuCatalogue`, `XcodeTarget`, `LeaderChoice` | `XCommanderCore/` | What an Xcode offers, which Xcode to talk to, which leaders are allowed. |
| `MenuScanner`, `SnapshotStore`, `ChangeReport`, `XcodeAXSchema` | `XcodeMenus/` | Scanning Xcode's menus, remembering them per Xcode build, reporting changes. |

### Why `XcodeContext` is a protocol

Accessibility is the least testable and most fragile part of the system, and the part most
likely to break when Apple ships a new Xcode. Putting it behind one protocol means every
question we ask Xcode is listed in one place (`XcodeContext.swift`), and the rest of the app
never touches an `AXUIElement` directly. If you're debugging "XCommander can't see X in Xcode",
start there.

## Threads

Almost everything runs on the **main thread**, and Swift's `@MainActor` enforces it. That's
deliberate:

- The event tap's run-loop source is added to the **main** run loop, so its callback runs on the
  main thread and can read app state without locks. The callback uses
  `MainActor.assumeIsolated` to tell the compiler so.
- AppKit windows must be used from the main thread anyway.
- Keyboard layout calls (`TISCopyCurrentKeyboardLayoutInputSource`) only work on the main thread.

The few things that move **off** the main thread do so because they're slow and would delay your
keystrokes (the tap shares the main run loop, so anything slow on main makes every key wait):

| Work | Where | Why |
|---|---|---|
| Re-reading Xcode's menu bar (~750 ms) | `XcodeContext.refreshMenuIndexInBackground` | Happens every time you switch to Xcode |
| ripgrep output | `ProjectSearch` | Streams results from a child process |
| Syntax colouring for the preview | `PreviewLoader`, `SourceKit` | Loading sourcekitd is slow the first time |
| Symbol index | `SymbolIndex` | Reading Xcode's index store |

Results always come back to the main actor before they touch UI or app state.

## What's stored where

| What | Where |
|---|---|
| Your keymap overrides | `~/.config/xcommander/config.toml` |
| Per-project overrides | `.xcommander.toml` in the project root |
| What each Xcode build's menus looked like | `~/.config/xcommander/xcode/<build>.json` |
| The report when a new Xcode changes something | `~/.config/xcommander/xcode/CHANGES.md` |
| Settings (enabled, leader, delays), recent files, first-run flag | `UserDefaults` for `dev.xcommander.XCommander` |

## Building

There are two ways to build, and both must keep working:

- **Xcode:** open `XCommander.xcodeproj` and run the `XCommander` scheme. The project is
  generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. If you add
  or remove files or change settings, edit `project.yml` and run `xcodegen`, don't edit the
  project by hand. Signing comes from `Config/Signing.xcconfig`.
- **Terminal:** `tools/xc.sh run` builds with SwiftPM, assembles the `.app` bundle by hand
  (SwiftPM can't make one), compiles the icons with `actool`, signs it and launches it. It's
  faster for quick iterations. `swift test` runs the tests.

Details in [Permissions, signing and the dev loop](docs/permissions-and-signing.md).

## Where to go next

- New to AppKit? → [AppKit for iOS developers](docs/appkit-for-ios-developers.md)
- Want to understand the keyboard side? → [The journey of a keystroke](docs/keystroke-journey.md)
- Want to understand how we talk to Xcode? → [Driving Xcode with Accessibility](docs/accessibility.md)
- Something broke? → [Debugging](docs/debugging.md)
- Why is it done *this* way? → [Decisions](docs/decisions.md)
