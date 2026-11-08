# AppKit for iOS developers

I came to this project knowing UIKit and SwiftUI from my iOS apps, and almost nothing about
AppKit. This page is what I had to learn to find my way around XCommander. It's not a full
AppKit course: it covers the parts this app uses, mapped to what you already know from iOS.

## The app has no window, and that's normal

An iOS app *is* its window. A Mac app can have zero, one or many, and can keep running with
none open. XCommander is a **menu-bar app** (Apple calls it an *agent*): no Dock icon, no main
menu, no window until it needs one.

Two settings make that happen:

- `LSUIElement = true` in `Info.plist` (set in `project.yml`, and in `Sources/xcdev/AppBuilder.swift` for the
  terminal build). This tells macOS at launch: no Dock icon, no app switcher entry.
- `NSApp.setActivationPolicy(.accessory)` at the top of `applicationDidFinishLaunching`
  (`AppDelegate.swift`). Same idea, from code.

There's no storyboard and no `@main`. `Sources/Companion/main.swift` creates the app by hand:

```swift
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

`NSApplication` is `UIApplication`'s cousin, and `NSApplicationDelegate` plays the role of your
`UIApplicationDelegate`. `app.run()` starts the main run loop and never returns.

## The menu bar item

`NSStatusItem` is the icon in the menu bar. There's no iOS equivalent.
`MenuBarController.swift` creates one with `NSStatusBar.system.statusItem(withLength:)`, gives
it an image and attaches an `NSMenu`. Clicking the icon shows the menu; each `NSMenuItem` has a
target and an action, like a `UIButton` with `addTarget`.

The icon is a **template image**: macOS ignores its colours and only uses its shape (the alpha
channel), so it's drawn black on a light menu bar and white on a dark one. If you give a status
item a coloured image, it stays coloured and looks out of place.

## Windows and panels

On iOS you rarely think about windows. On the Mac, every window is an `NSWindow`, and its
behaviour is set by a handful of properties. XCommander uses two very different kinds.

### Normal windows: Settings and the first-run window

`SettingsWindow.swift` and `FirstRunWindow.swift` are SwiftUI views hosted in AppKit, the same
trick as `UIHostingController` on iOS:

```swift
let controller = NSHostingController(rootView: content)
let window = NSWindow(contentViewController: controller)
window.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
```

`makeKeyAndOrderFront` brings the window forward and makes it the **key window** (the one that
receives keyboard input). Because XCommander is an agent app, it also has to activate itself, or
the window can appear behind whatever app is in front.

### Panels that never take focus: the which-key panel and the pickers

This is the most important AppKit idea in the project. When the which-key panel or a picker
appears, **Xcode must stay the active app**, with its editor focused and its selection intact.
If our window became key, Xcode would dim, and a picker that acts on the current selection would
have nothing to act on.

So the overlays are `NSPanel`s configured not to take focus (`OverlayController.swift`,
`PickerOverlay.swift`):

```swift
let panel = NSPanel(contentRect: ..., styleMask: [.borderless, .nonactivatingPanel], ...)
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.orderFrontRegardless()
```

| Setting | What it does |
|---|---|
| `.borderless` | No title bar, no frame. We draw everything ourselves. |
| `.nonactivatingPanel` | Clicking or showing it doesn't activate our app. Xcode stays active. |
| `.floating` level | Sits above normal windows, so it's drawn over Xcode. |
| `.canJoinAllSpaces`, `.fullScreenAuxiliary` | Shows up on any Space, including over a full-screen Xcode. |
| `orderFrontRegardless()` | Shows the window *without* making it key or activating the app. |

But if the picker never becomes key, how does it receive typing? It doesn't: **the event tap
gives it the keys.** While a picker is open, `AppDelegate.handleKey` sends every key to
`PickerSession` (in Core) instead of letting it reach Xcode. The price is that we draw our own
text field and caret and handle every editing key ourselves. That's what `Picker.swift` does.

## Coordinates: the y axis is upside down

On iOS, the origin is the top-left and y grows downward. In AppKit, **the origin is the
bottom-left of the main screen and y grows upward**. To make it more fun, the Accessibility API
reports Xcode's window frame in **top-left** coordinates, like iOS.

So whenever we place a panel relative to Xcode's window, we have to flip:

```
cocoaY = mainScreenHeight - axY - height
```

Look for the comment "AX reports top-left origin coordinates; Cocoa windows are bottom-left" in
`OverlayController.swift`. The flip is always against the **primary** screen's height (the one
with the menu bar), not the screen the window is on. Getting that wrong only shows up on
multi-monitor setups.

Views can opt back into a top-left origin by overriding `isFlipped` to return `true`. Both
overlay views do that, because laying out rows of text from the top is more natural.

## Drawing

There's no `UILabel` stack here. The panels are custom `NSView` subclasses that draw themselves
in `draw(_:)`, much like overriding `draw(_ rect:)` in a `UIView`:

- Text is drawn with `NSAttributedString.draw(at:)` / `draw(in:)`, using fonts from
  `NSFont.systemFont` and `NSFont.monospacedSystemFont`.
- Shapes use `NSBezierPath` (the AppKit `UIBezierPath`).
- `needsDisplay = true` is AppKit's `setNeedsDisplay()`.

Why AppKit drawing and not SwiftUI for the overlays? Not for speed. The two things SwiftUI
brings are things these panels can't use: they're never key, so there's no focus to drive state
from, and they measure their own text to decide how tall the window should be *before* showing
it, which is the opposite of the direction SwiftUI lays out in. What's left is a dozen strings
already laid out, and `NSAttributedString.draw(at:)` puts them on screen with nothing in
between. The Settings window is an ordinary window, so it's SwiftUI.

Colours come from `Theme.swift`. The overlays use fixed colours that match Xcode's dark editor
theme, rather than system colours that follow light or dark mode, because they're drawn on top
of Xcode, whose theme is independent of the system appearance.

## The run loop, timers and the main thread

On iOS you rarely touch the run loop directly. Here it matters, because **the event tap's
callback runs on the main run loop**. Everything on the main thread competes with your
keystrokes: if the main thread is busy for 300 ms, your next key waits 300 ms.

That's why:

- Timers are added in `.common` mode (`RunLoop.main.add(timer, forMode: .common)`) so they
  still fire while a menu is open or the user is dragging something.
- Slow work (scanning Xcode's menus, running ripgrep, loading sourcekitd) runs on a background
  queue and hands its result back to the main actor.
- Almost every type in `Companion` is marked `@MainActor`, so the compiler stops you from
  touching it from the wrong thread.

## Watching other apps: NSWorkspace

`NSWorkspace` is how a Mac app learns about *other* apps. XCommander listens to two
notifications (`observeFrontmostApplication()` in `AppDelegate.swift`):

- `didActivateApplicationNotification`: some app came to the front. If it's Xcode, XCommander
  arms itself, re-reads Xcode's menus in the background and starts following its window. If
  Xcode just lost the front, any half-typed sequence is abandoned.
- `didTerminateApplicationNotification`: Xcode quit (for example, to update). XCommander resets
  and switches to another Xcode if one is still running.

Every copy of Xcode (release, beta) has the same bundle identifier, `com.apple.dt.Xcode`, so
"which Xcode?" is a real question. `XcodeTarget.swift` in Core answers it.

## NSEvent vs CGEvent

You'll see two event types:

- `NSEvent` is AppKit's event, delivered to *your own* windows. XCommander barely uses it,
  because its windows never receive keys.
- `CGEvent` is the lower-level Core Graphics event that the event tap sees for *every* app.
  That's what XCommander works with. See [The journey of a keystroke](keystroke-journey.md).

## Logging

The app logs with `os.Logger`, under the subsystem `dev.xcommander.XCommander`, with a
category per area (`tap`, `menus`, `executor`, `panes`, …). Two things surprised me:

- String interpolation is **redacted** by default in release logs. `\(value)` shows up as
  `<private>` unless you write `\(value, privacy: .public)`.
- `.debug` messages aren't stored; you only see them live in `log stream`. `.notice` and above
  are kept and can be read later with `log show`.

See [Debugging](debugging.md) for the commands.

## Further reading

- Apple's [AppKit documentation](https://developer.apple.com/documentation/appkit), especially
  `NSWindow`, `NSPanel` and `NSStatusItem`.
- [Cocoa Programming for OS X](https://www.bignerdranch.com/books/) (Big Nerd Ranch) is old but
  still the clearest introduction to how AppKit thinks.
- Reading open-source menu-bar apps is the fastest way to learn the idioms. Rectangle, Ice and
  AltTab are good examples.
