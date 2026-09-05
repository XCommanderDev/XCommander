import AppKit

// A menu-bar app: no Dock icon, no main menu, no window until the overlay wants one.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
