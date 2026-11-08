# Decisions

The choices that shape XCommander, and why. When something in the code looks odd, the reason is
probably here. Each entry says what was decided, why, and what it costs. If you want to change
one of these, open an issue first: most of them were learned the hard way.

---

### A menu-bar app outside Xcode, not an Xcode extension

**Why:** Xcode has had no plugin system since Xcode 8, and Source Editor Extensions only see the
text of one file. Changing keys, panes and navigation needs an app that drives Xcode from outside
with an event tap and the Accessibility API.
**Cost:** needs the Accessibility permission, can't be sandboxed, so never on the Mac App Store.

### Logic in a package with no AppKit

**Why:** the keymap, the session, matching, geometry, config parsing and the preview model are
plain Swift in `XCommanderCore`, so about 360 tests run headless in under a second. The AppKit
side stays thin enough to check by reading it.
**Cost:** a translation layer at the boundary (`EventBridge`, `XcodeContext`).

### The leader is a chord that can't be typed as text

**Why:** the leader is swallowed while Xcode is in front. The first leader, `⇧Space`, armed a
sequence whenever Shift was held a beat too long across a word break, and the next word ran as a
command. `⌥Return` and the other choices can't happen while typing code.
**Cost:** no key recorder. Users pick from a short list (`LeaderChoice`).

### A keymap node is a command or a group, never both

**Why:** if a key could be both, the engine would have to wait to see whether another key
follows. No ambiguity means no timeouts, and every key resolves instantly.
**Cost:** you can't bind `b` and `b b` at the same time.

### Unbound keys are swallowed; expired sequences pass the key through

**Why:** both protect your source file. A mistyped sequence must not drop a stray character into
it, and a key typed after you walked away from a sequence was meant for the file.

### The which-key panel waits 350 ms

**Why:** if you type the sequence fluently, you never see the panel. It only appears when you
pause, so it helps without flashing at you all day.

### Bindings follow the character, not the key position

**Why:** a keycode is a physical position. A binding for `/` must work wherever `/` is on your
keyboard (AZERTY, QWERTZ…). Chords with ⌃⌥⌘ keep explicit modifiers, like macOS menu shortcuts.

### Commands are named by the menu item's action (`AXIdentifier`)

**Why:** titles change between Xcode versions and languages; Xcode 27 renamed four bound items.
The action behind an item survives renames, moves and translations.
**Cost:** identifiers aren't documented by Apple. They can change too, which is what `MenuRef`
alternates and the [upgrade process](xcode-upgrades.md) are for.

### Press the menu item; don't post its shortcut

**Why:** posting a shortcut makes macOS flash the menu title in the menu bar. `AXPress` is
silent and takes about 1 ms. Posting the shortcut is kept as a fallback.
**Rejected:** writing custom shortcuts into Xcode's preferences. It changes another app's
settings, collides with the user's own shortcuts and needs Xcode restarted.

### Overlays never take focus

**Why:** Xcode must stay active with its selection intact, so a picker can act on the selection.
The event tap feeds keys to the picker instead.
**Cost:** we draw our own text field and handle every editing key ourselves.

### Nothing slow on the main thread

**Why:** the event tap runs on the main run loop. Anything slow there delays every keystroke.
Scanning menus, search, symbol loading and syntax colouring run in the background.

### Borrow Xcode's own tools instead of shipping our own

**Why:** symbols come from the index Xcode already maintains (`libIndexStore`), syntax colour
from Xcode's own `sourcekitd`, both loaded with `dlopen` from the selected Xcode. Running a
second language server would contradict the idea of the app. Loading at runtime means a missing
library costs one feature, not the app.

### Trust a new Xcode only after it has settled

**Why:** after an update Xcode opens on its Welcome window, where a quarter of the shipped
bindings are missing from the menus. Nothing is hidden or reported until a scan with a source
editor focused. See [Surviving Xcode upgrades](xcode-upgrades.md).

### Configuration in a TOML file, applied whole or not at all

**Why:** `~/.config` is where developers keep their tool settings, and a file can be shared and
committed. A broken file never half-applies: you keep the last good keymap and get a message.

### One third-party dependency: Sparkle, for updates

**Why:** the app reads keystrokes on your machine, so every dependency is code with that access.
The TOML reader and the argument parsing in `xcmdr` are small and written by hand. The one
exception is [Sparkle](https://sparkle-project.org), because updating an app safely is hard to get
right and Sparkle is what most Mac apps outside the App Store use: open source, widely audited,
and it checks every update against both an EdDSA key and the app's Developer ID before installing
it. It's linked only into the app Xcode builds. A build made with `xcdev` leaves it out and never
updates itself.
**Cost:** a pinned version to keep up with (`project.yml`), and a signing key to look after. If
the private key is lost, installed copies can't verify updates any more, so it's backed up.

### The Xcode project is generated

**Why:** `project.yml` is short, readable and merges cleanly; a `.pbxproj` isn't. XcodeGen
generates `XCommander.xcodeproj`, which is committed so the repo opens without installing it.

### Free and open source under GPLv3, with a protected name and icon

**Why:** I want XCommander to be free, in the tradition of the developer tools I love, and
improvements to stay open. The name and icon are kept for the official build so a fork can't
pass itself off as it. See [TRADEMARKS.md](../TRADEMARKS.md).
