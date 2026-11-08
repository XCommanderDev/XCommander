# The journey of a keystroke

Everything XCommander does starts with a key press. This page follows one key from your
keyboard to an Xcode command, and explains the macOS machinery and the design rules along the
way. Keep `Sources/Companion/EventTap.swift`, `Sources/Companion/AppDelegate.swift`
(`handleKey`) and `Sources/XCommanderCore/KeymapSession.swift` open while you read.

## 1. Where a key goes on macOS

When you press a key, the keyboard driver hands it to the **WindowServer**, the process that
owns the screen and decides which app gets which event. Before delivering the key to the active
app, the WindowServer passes it through any **event taps** that are installed. An event tap is
a callback that sees the event and can let it through, change it, or swallow it.

```
keyboard → driver → WindowServer → [event taps] → active app (Xcode)
                                         ▲
                                  XCommander's tap
```

There are taps at several levels. XCommander uses a **session tap** at the **head** of the
queue (`.cgSessionEventTap`, `.headInsertEventTap`), so it sees keys before anything else in
your login session. It asks only for key-down events. And it's an active tap (`.defaultTap`),
not a listen-only one, because it needs to *swallow* keys.

Creating a tap requires the **Accessibility** permission. Without it, `CGEvent.tapCreate`
returns `nil`, which is how the app knows to ask (see
[Permissions, signing and the dev loop](permissions-and-signing.md)).

## 2. The tap callback, and its rules

The callback is a C function pointer, so it can't capture Swift context. The usual trick is to
pass `self` as an opaque pointer (`userInfo`) and get it back inside:

```swift
let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
```

The tap's run-loop source is added to the **main** run loop, so the callback runs on the main
thread. That's why it can call into `@MainActor` code with `MainActor.assumeIsolated`, without
an async hop. It returns either the event (pass through) or `nil` (swallow).

Three facts about taps shape this file. Each one is handled in `EventTap.swift`:

1. **macOS disables a slow tap.** If the callback takes too long, the system disables the tap
   and sends a `.tapDisabledByTimeout` event. The callback re-enables it right there. A health
   timer also checks every 250 ms, just in case.
2. **Secure input starves every tap.** When any app turns on secure input (a password field,
   some terminals), *no* tap receives keys, system-wide. There's no callback or notification,
   and the tap still reports itself as enabled. The only way to know is to poll
   `IsSecureEventInputEnabled()`, which the same 250 ms timer does. The menu bar then shows a
   padlock, so you know why nothing works.
3. **Every microsecond counts.** The callback runs for every key you type in every app. It
   only reads in-memory state and decides. It never asks the system anything slow, and never
   runs a command itself.

## 3. Is this key for us?

`AppDelegate.handleKey` gets the keycode and modifier flags and makes the cheap checks first:

- XCommander is switched off from the menu → pass.
- Xcode isn't the frontmost app → pass. (This flag is kept up to date by an `NSWorkspace`
  notification, because asking the system "who's in front?" on every key would be too slow.)

## 4. Turning a keycode into a key

A **keycode** is a physical position on the keyboard, not a character. Keycode 0 is the key
labelled A on a US keyboard and Q on a French one. If bindings were stored as keycodes, every
binding would land on the wrong key for anyone with a different layout.

So `EventBridge.keyEvent` asks the current keyboard layout what this key produces, with and
without Shift (`KeyboardLayout.swift`, which uses `TISCopyCurrentKeyboardLayoutInputSource` and
`UCKeyTranslate`). Then `KeyIdentity` in Core applies one rule:

> **A character key is identified by the character it produces.**

Shift is folded into the character: `⇧/` on AZERTY produces `:`, so it *is* `:`. A binding for
`/` fires wherever `/` lives on your keyboard. The exception is a **chord** with Control, Option
or Command: there the modifier is the point, so the unshifted character plus explicit modifiers
identifies it, which is also how macOS matches menu shortcuts. Keys with no character (Return,
Escape, arrows) are `SpecialKey`s and keep their modifiers.

The result is a `KeyEvent`, a plain value type in Core that the rest of the engine speaks.

## 5. The leader

Nothing happens until you press the leader. The default is <kbd>⌥</kbd><kbd>↩</kbd>, and the
choices are a short fixed list (`LeaderChoice.swift`): `⌥RET`, `⌘ESC`, `⌃RET`, `⌃SPC`, `⌥SPC`.

Why not a key recorder? Because the leader is swallowed while Xcode is in front, so **a leader
that can be typed as text is a trap**. The first version used `⇧Space`. If you held Shift a beat
too long across a word break, the space armed a sequence and the *next word* you typed ran as a
command. Testing ordinary English words, nine out of eighteen reached a command. A chord over a
key that types nothing can't happen by accident, so the list only contains those.

Each `LeaderChoice` also declares which Xcode shortcut it hides (`⌃SPC` hides Show Completions,
for example), and a test checks those claims against a real scan of Xcode's menus.

## 6. The session: a small state machine

`KeymapSession` is a struct in Core. It's either idle or partway through a sequence, and
`press(_:)` returns a `SessionOutcome`:

| Outcome | When | The tap |
|---|---|---|
| `.passThrough` | Idle, and this isn't the leader | lets the key through |
| `.awaiting(panel)` | The leader, or a key that leads to a group | swallows it, schedules the which-key panel |
| `.fired(commandID)` | A key that reaches a command | swallows it, runs the command |
| `.cancelled(reason)` | Esc, an unbound key, a timeout, or the sequence was abandoned | swallows it, hides the panel |

The keymap it walks is a **trie** (`Keymap.swift`): each node is either a command or a group,
**never both**. That rule removes every timeout from the engine. If `b` could be both a command
and a prefix for `b b`, pressing `b` would mean waiting to see whether another key follows, and
waiting is what makes modal editors feel slow. With the rule, every key resolves instantly.

A few rules that look odd until you see the reason:

- **An unbound key is swallowed, not passed on.** If you mistype `⌥RET m x`, the `x` is eaten.
  Passing it on would drop a stray character into your source file.
- **An expired key *is* passed on.** If you armed a sequence and walked away, the sequence
  expires after 10 seconds of inactivity, and the next key goes to Xcode. Swallowing it would be
  the same defect in another form: a key you meant for your file, eaten.
- **Esc cancels from any depth**, and pressing the leader again restarts the sequence.
- **Anything that takes you away** (switching apps, the tap being interrupted by secure input
  or a timeout) calls `abandon()`, so every way out resets the same way.

Because the session is pure (no timers, no UI, the clock is passed in), all of this is covered
by unit tests in `Tests/XCommanderCoreTests/KeymapSessionTests.swift`.

## 7. The which-key panel

On `.awaiting`, `OverlayController.present(_:)` doesn't show the panel straight away. It starts
a **350 ms timer**. If you type the whole sequence quickly, the command fires before the timer
does, and you never see the panel. If you pause, it appears, pinned to the bottom of Xcode's
window. This delay is what keeps the tool from flashing at you all day.

The panel lists only commands this Xcode actually offers (`availabilityProvider`), and shows
each command's own Xcode shortcut, dimmed, so the panel also teaches you Xcode's shortcuts.

## 8. Running the command

On `.fired(id)`, `handleKey` hides the panel and schedules the command on the **next turn of
the run loop**:

```swift
DispatchQueue.main.async { [weak self] in self?.run(commandID) }
```

That matters: some commands post a synthetic key event, and posting one from inside the tap
callback would re-enter our own tap before it has returned.

`run` looks the id up in the `CommandRegistry` and hands the `Command` to `CommandExecutor`,
which picks a route based on the command's `CommandAction`. The usual route is pressing the
matching Xcode menu item over Accessibility. That's the next guide:
[Driving Xcode with Accessibility](accessibility.md).

## Adding a binding

Shipped bindings live in `Sources/XCommanderCore/DefaultKeymap.swift`, in two tables:

1. `commands`: register the command once, with an id, a title and an action. Most are menu
   items named by their action, for example:

   ```swift
   .menu("make.build", "build", MenuRef("buildActiveRunContext:")),
   ```

   To find a menu item's action identifier, use `xcmdr resolve` or `xcmdr list` (see
   [Debugging](debugging.md)), or the Accessibility Inspector.
2. `bindings`: bind a key sequence to the id:

   ```swift
   (["m", "m"], "make.build"),
   ```

Then run `swift test`. The tests build the whole keymap (a conflict fails loudly) and check
that every menu identifier exists in the recorded Xcode scan in `Fixtures/`.

Users can also add and override bindings without rebuilding, in a config file. See
[Configuration](configuration.md).
