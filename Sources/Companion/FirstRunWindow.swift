import AppKit
import AutographeCore
import SwiftUI

/// What the user sees *before* macOS asks for Accessibility.
///
/// The system alert cannot be softened. Its wording is fixed, there is no purpose-string key
/// for this service — `NSAccessibilityUsageDescription` is folklore; TCC never reads it — and
/// it tells the user, correctly, that this app wants to control their computer. An app that
/// calls `AXIsProcessTrustedWithOptions` from `applicationDidFinishLaunching` has therefore
/// made that sentence the first thing it ever says to anyone.
///
/// So this window takes the moment before it. It cannot change the alert; it can make sure the
/// user has already decided by the time the alert arrives. Three things earn that decision, and
/// nothing else in here is worth the user's attention:
///
/// - **The mark.** `NSApp.applicationIconImage` is the same image macOS is about to draw in its
///   own alert, so the two read as one app rather than two events. Chapter 21 makes the
///   argument at length: a generic placeholder is the worst possible answer to *"do I trust
///   this?"*, and this window is where that answer is given first.
/// - **Naming the wording before macOS does.** Telling someone in advance that the next prompt
///   will sound alarming, and that it is fair, costs one sentence and disarms it. Discovering
///   it cold does not.
/// - **The exhaustive list.** "Watches one key, reads Xcode's menus, nothing else" is checkable
///   and narrow. Reassurance that is not checkable reads as marketing, which is worse than
///   saying nothing.
///
/// Shown once, ever. A window that returns every launch is a window people learn to dismiss
/// without reading, and by then it has spent the only attention it was ever going to get.
@MainActor
final class FirstRunWindow {

    private enum Key {
        static let seen = "firstRunSeen"
    }

    /// False once the window has been shown, whatever the user then chose. Declining is a
    /// decision too, and the menu's `Open Accessibility Settings…` is the way back.
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: Key.seen)
    }

    /// Called when the user is ready for the system to ask. The delegate owns the prompt; this
    /// window's whole job is the sentence before it.
    var onContinue: (() -> Void)?

    private var window: NSWindow?

    func show() {
        UserDefaults.standard.set(true, forKey: Key.seen)
        if window == nil { build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Like the settings window, and unlike every panel in this app: we are talking to the
        // user about this app, so it should come properly to the front.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called by the permission poll. If the user grants it from System Settings while this is
    /// still up, the window has said everything it had to say.
    func close() {
        window?.close()
    }

    private func build() {
        let content = FirstRunView(
            leader: SettingsWindow.leader.title,
            onContinue: { [weak self] in
                self?.close()
                self?.onContinue?()
            },
            onLater: { [weak self] in self?.close() })

        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        self.window = window
    }
}

/// The copy is the feature here, so it is worth saying why it is shaped the way it is.
///
/// It states the permission's breadth rather than minimising it, then answers it with a list
/// that is exhaustive and checkable — one key, the menus, nothing else. Narrow claims a
/// sceptic can verify are worth more than warm ones they cannot, and nothing here asks to be
/// taken on trust. It closes on the two facts rather than any assurance: the build is
/// notarised, and the permission is revocable.
private struct FirstRunView: View {

    let leader: String
    let onContinue: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                // The app's own icon, which is also the one the system alert will show.
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autographe")
                        .font(.system(size: 22, weight: .semibold))
                    Text("A keyboard layer for Xcode.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("""
                Xcode has around seven hundred menu commands and fewer than a third of them \
                have a keyboard shortcut. Autographe puts the rest a few keystrokes away.
                """)

            Text("""
                For that, macOS has to grant it Accessibility — the only permission that lets \
                an app see a keystroke and press a menu item on your behalf. The prompt after \
                this one is the system's own, and it is blunt: it says this app wants to \
                control your computer. That is fair. The permission really is that broad, so \
                here is everything Autographe does with it:
                """)

            VStack(alignment: .leading, spacing: 6) {
                bullet("Watches for one key, \(leader), and only while Xcode is in front.")
                bullet("Reads Xcode's menus, and presses the item you choose.")
                bullet("Nothing else. No network connections, no analytics, nothing leaves this Mac.")
            }
            .padding(.leading, 2)

            Text("""
                Autographe is signed and notarised by Apple. You can revoke this permission at \
                any time in System Settings.
                """)
            .foregroundStyle(.secondary)

            HStack {
                Text(verbatim: "autographe.app")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Not Now", action: onLater)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 460)
    }

    /// A hanging indent, so a bullet that wraps stays aligned under its own text rather than
    /// under the dot. `Label` would do this with an SF Symbol, but a filled dot at body size is
    /// heavier than the text it marks.
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "•")
            Text(text)
        }
    }
}
