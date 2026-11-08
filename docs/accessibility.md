# Driving Xcode with Accessibility

The Accessibility API is how VoiceOver reads the screen and how apps like Keyboard Maestro
press buttons in other apps. It's also how XCommander reads Xcode's menus, finds its panes,
reads and replaces the selected text, and runs commands. Almost all of that code lives in
`Sources/Companion/XcodeContext.swift`, `Sources/XcodeMenus/` and
`Sources/Companion/PaneController.swift`.

## The model: a tree of elements

Every app exposes its UI as a tree of **elements** (`AXUIElement`). An element has:

- a **role**: `AXWindow`, `AXMenuBar`, `AXMenuItem`, `AXButton`, `AXTextArea`, `AXScrollArea`…
- **attributes** you can read, and sometimes write: `AXTitle`, `AXPosition`, `AXSize`,
  `AXChildren`, `AXFocused`, `AXSelectedText`, `AXIdentifier`…
- **actions** you can perform: `AXPress`, `AXShowMenu`, `AXCancel`…
- **notifications** you can subscribe to: `AXWindowMoved`, `AXFocusedUIElementChanged`…

You start from the application element and walk down:

```swift
let app = AXUIElementCreateApplication(pid)

var value: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
let window = value as! AXUIElement
```

It's a C API from the Carbon era, so it's verbose: every value comes back as a `CFTypeRef` you
have to cast, and every call returns an `AXError` you should check. The code wraps the common
calls in small helpers so the rest reads normally.

**The best tool for this is the Accessibility Inspector**, which ships with Xcode (Xcode menu →
Open Developer Tool → Accessibility Inspector). Point it at any part of Xcode and it shows that
element's role, attributes and actions. When I need to know "how would I find X in Xcode?", I
start there.

## Every call is a message to another process

Reading an attribute isn't like reading a property. It sends a message to Xcode, waits for
Xcode's main thread to answer, and comes back. That has consequences:

- **It's slow compared to normal code.** Reading a window frame takes about 0.5 ms typically,
  and tens of milliseconds at worst. Walking Xcode's whole menu bar takes about 750 ms. That's
  why none of it happens in the event tap callback, and why the menu walk runs off the main
  thread.
- **It can hang.** If Xcode's main thread is busy (a modal sheet, a long build step), calls
  block until a timeout. The default is 1.5 s. XCommander lowers it to 0.25 s with
  `AXUIElementSetMessagingTimeout`, because a late answer is useless for placing a panel.
- **Elements belong to a process.** When Xcode quits and relaunches (every update does), every
  `AXUIElement` we held becomes meaningless. `appElement()` in `XcodeContext.swift` notices the
  process ID changed and starts over.

## Reading the menu bar

XCommander's main way of running commands is pressing Xcode's own menu items. To do that it
needs an index of every menu item, which `MenuScanner` builds by walking
`AXMenuBar → AXMenuBarItem → AXMenu → AXMenuItem → …`. For each item it records:

| Attribute | What it gives |
|---|---|
| `AXIdentifier` | The Objective-C **action** behind the item, like `buildActiveRunContext:`. This is how commands are named. |
| `AXTitle` | The visible title, like "Build". Used for display only. |
| `AXMenuItemCmdChar`, `AXMenuItemCmdModifiers`, `AXMenuItemCmdVirtualKey` | The item's keyboard shortcut. |
| `AXEnabled` | Whether it can be pressed right now. |

The result is a `MenuSnapshot`, which Core turns into a `MenuCatalogue`, the lookup table that
resolves a command's `MenuRef` to a real item.

Some things I learned the hard way, all handled in the code:

- **Use the identifier, not the title.** Titles change between Xcode versions (Xcode 27 renamed
  four items XCommander binds) and between languages. Some titles even contain the name of the
  open file. The action identifier stays the same.
- **The menus depend on what's on screen.** The Editor menu has a handful of items with no
  editor focused and over a hundred with a Swift file open. One scan only shows one context.
- **The menus are inert when Xcode isn't in front.** Many items are disabled or missing while
  another app is active. That's why `xcmdr` brings Xcode forward before scanning, and why a
  test that forgets to will report working features as broken.
- **Shortcut characters come back in the current keyboard layout**, and letters are upper-cased
  for display. The modifier mask is the only reliable statement about Shift.

## Pressing a menu item

Once an item is in the index, running it is one call:

```swift
AXUIElementPerformAction(item.element, kAXPressAction as CFString)
```

It takes about 1 ms and is invisible. XCommander first tried the obvious alternative, posting the
item's keyboard shortcut as a synthetic key event, but macOS **flashes the menu's title** in the
menu bar when a shortcut matches a menu item, which looks like something is clicking through your
menus. Pressing the item over Accessibility doesn't. Posting the shortcut remains the fallback
when a press is refused (`CommandExecutor.swift`).

A few commands exist only in a **toolbar popup**, not in the menu bar (for example "new editor
tab"). `PopupReader` opens the popup with `AXShowMenu`, finds the item and presses it. It's
slower and visible, so it's used only where there's no other way.

## Beyond menus

Some features need more than pressing menu items:

| Feature | How | Where |
|---|---|---|
| **The panels follow Xcode's window** | Read the focused window's `AXPosition` and `AXSize`; subscribe to `AXWindowMoved`, `AXWindowResized` and `AXFocusedWindowChanged` with an `AXObserver` | `WindowTracker.swift` |
| **Current file** | The window's `AXDocument` attribute (a file URL) | `XcodeContext.documentURL()` |
| **Text transforms** | The editor is an `AXTextArea`. `AXSelectedText` and `AXSelectedTextRange` are **writable**, and a write joins Xcode's own undo stack, so ⌘Z undoes it | `XcodeContext.replaceSelection(with:)` |
| **Open editors (buffers)** | Each editor pane may have an `AXTabGroup` whose tabs can be pressed | `XcodeContext.openEditors()` |
| **Moving between panes** | Each editor pane is an `AXScrollArea` with a frame; setting `AXFocused` moves focus; an `AXSplitter`'s `AXValue` moves the divider | `PaneController.swift`, with the geometry in Core's `PaneLayout.swift` |
| **Navigator, inspector, debug area** | Mostly menu items; focusing a specific area needs Accessibility | `AreaController.swift` |

### Observers

`AXObserver` is the push alternative to polling. You create one for a process, register for
notifications on specific elements, and add its run-loop source to your run loop. Two details:

- Notifications are registered on an *element*, so when Xcode's focused window changes, the
  window observers have to be moved to the new window.
- An observer belongs to *one process*. When Xcode relaunches, or you switch between a release
  and a beta, the observer is dead. That's why `WindowTracker` has `follow()`, called whenever
  Xcode comes to the front, rather than a `start()` that runs once.

## Fragile assumptions, listed in one place

Some of what XCommander does depends on how Xcode's window is built: that editor panes are
`AXScrollArea`s, that the navigator is an `AXOutline`, and so on. Apple doesn't document any of
that and can change it in any release. Those assumptions are gathered in
`Sources/XcodeMenus/XcodeAXSchema.swift`, which can check them against the running Xcode. If a
pane command fails, the app runs that check to tell "Xcode changed its window" apart from an
ordinary failure. `xcmdr doctor` runs it too.

## Further reading

- Apple: [Accessibility for macOS](https://developer.apple.com/documentation/applicationservices/axuielement_h)
  (the `AXUIElement.h` reference) and the header itself, which is better documented than the
  website.
- Open-source apps that use this API heavily, worth reading: Rectangle (window management),
  AltTab, and Hammerspoon's `hs.axuielement` module.
