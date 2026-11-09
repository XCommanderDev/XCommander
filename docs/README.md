# XCommander docs

These pages are for anyone who wants to understand, fix or extend XCommander, including future
me. I'm an iOS developer who learned AppKit, event taps and the Accessibility API while building
this, so the guides assume you know Swift and some UIKit or SwiftUI, and nothing about macOS
internals.

## Start here

1. **[Architecture](../ARCHITECTURE.md)**: the map. Targets, the keystroke path, who owns what,
   threads, where things are stored.
2. **[AppKit for iOS developers](appkit-for-ios-developers.md)**: menu-bar apps, windows that
   never take focus, upside-down coordinates, the run loop.
3. **[The journey of a keystroke](keystroke-journey.md)**: event taps, keyboard layouts, the
   leader, the session state machine, the which-key panel.
4. **[Driving Xcode with Accessibility](accessibility.md)**: reading Xcode's menus, pressing
   items, following its window, editing the selection, panes.

## When you need it

- **[Permissions, signing and the dev loop](permissions-and-signing.md)**: building, running,
  why the Accessibility grant keeps disappearing, and what releasing involves.
- **[Debugging](debugging.md)**: logs, `xcmdr doctor`, the Accessibility Inspector, common
  problems.
- **[Configuration](configuration.md)**: the `config.toml` format, for users and for working on
  the config code.
- **[Surviving Xcode upgrades](xcode-upgrades.md)**: how the app absorbs Xcode changes, the
  `xcmdr` tool, and how to help with an Xcode beta.
- **[Decisions](decisions.md)**: why things are the way they are.

## A first week with the code

If you learn best by doing, as I do, here's a path through the codebase. Each step is an hour or
two: read the files, read their tests, change something, watch a test fail, put it back.

| Day | Read | Try |
|---|---|---|
| 1 | `Companion/main.swift`, `AppDelegate.applicationDidFinishLaunching`, `MenuBarController` | Run the app, change the text of a menu item |
| 2 | `EventTap.swift`, `AppDelegate.handleKey`, `EventBridge`, `KeyIdentity` | Write a test that feeds `KeymapSession` a sequence and checks each decision |
| 3 | `KeymapSession`, `Keymap`, `DefaultKeymap` and their tests | Add a binding, then add a test for it |
| 4 | `OverlayController`, `WindowTracker` | Change the panel's delay or position |
| 5 | `XcodeContext`, `CommandExecutor`, `MenuScanner` | Bind a menu item that isn't bound yet, found with `xcmdr list` |
| 6 | `Picker.swift`, `FuzzyMatcher`, `PickerOverlay` | Change how picker results are ranked |
| 7 | `PaneController`, `PaneLayout`, `XcodeAXSchema` | Use the Accessibility Inspector on Xcode's editor panes |

The tests are the best documentation of the rules: each one names a situation, often a bug that
really happened.
