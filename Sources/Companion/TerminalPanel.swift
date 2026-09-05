import AppKit
import CompanionCore
import SwiftTerm
import os

/// A terminal, because Xcode does not have one.
///
/// Every other editor has an integrated terminal; Xcode has the LLDB console and nothing
/// else. So this one is ours: a floating panel with a real shell in it, opened at the
/// project root.
///
/// **It is docked, not floating.** A window of its own hanging over Xcode reads as a
/// separate app; the point is a terminal that belongs to the editor. So it is borderless,
/// sized to the editor area, pinned to the bottom inner edge of Xcode's window, and it
/// follows that window when it moves, resizes or goes full-screen — the same trick as the
/// which-key panel. We cannot put a view *inside* Xcode's process, since there is no plugin
/// system to do it with, but from the outside this is indistinguishable.
///
/// **It takes keyboard focus, unlike every other window in the app.** The which-key and
/// picker overlays deliberately never become key, because Xcode has to keep its selection.
/// A terminal is the opposite: it is useless unless keystrokes reach the shell.
/// `⌥Escape` hands focus back to Xcode.
@MainActor
final class TerminalPanel: NSObject {

    /// A borderless panel will not become key unless it says it can, and a terminal that
    /// cannot take the keyboard is a picture of a terminal.
    private final class DockedPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private var window: NSPanel?
    private var context: XcodeContext?
    /// How much of Xcode's window height the terminal takes.
    private var heightFraction = 0.32
    private var terminal: LocalProcessTerminalView?
    private var monitor: Any?
    private var startedAt: URL?

    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "terminal")

    var isVisible: Bool { window?.isVisible ?? false }

    /// Show it, or hide it if it is already up. The shell keeps running either way: a
    /// terminal you have to restart is not a terminal you would use.
    func attach(to context: XcodeContext) { self.context = context }

    func toggle(at root: URL?) {
        if isVisible {
            hide()
        } else {
            show(at: root)
        }
    }

    func show(at root: URL?) {
        ensureWindow(at: root)
        guard let window else { return }
        dock()
        // If the project changed since the shell started, say so rather than silently
        // running commands in the wrong directory.
        if let root, let startedAt, root != startedAt {
            terminal?.feed(text: "\r\n\u{1b}[33m# project is now \(root.path)\u{1b}[0m\r\n")
            self.startedAt = root
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let terminal { window.makeFirstResponder(terminal) }
    }

    func hideIfVisible() {
        guard isVisible else { return }
        window?.orderOut(nil)
    }

    func hide() {
        window?.orderOut(nil)
        // Put the user back where they were rather than leaving focus nowhere.
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
            .first?
            .activate()
    }

    private func ensureWindow(at root: URL?) {
        if window != nil { return }

        let frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        let panel = DockedPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // A thin lip along the top so the terminal reads as a panel of the editor rather
        // than a rectangle dropped on top of it.
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1

        let view = LocalProcessTerminalView(frame: frame.insetBy(dx: 1, dy: 1))
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        panel.contentView = container
        terminal = view

        // The user's own shell, and their own login environment with it — a terminal that
        // does not know about your PATH is a toy.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if let root { environment.append("PWD=\(root.path)") }
        startedAt = root
        view.startProcess(executable: shell,
                          args: ["-l"],
                          environment: environment,
                          execName: nil)
        if let root {
            // `cd` rather than a working-directory argument, because a login shell will
            // have run the user's rc files and may have moved elsewhere.
            view.send(txt: "cd \(root.path.replacingOccurrences(of: " ", with: "\\ "))\n")
        }

        window = panel
        dock()
        installEscapeMonitor()
    }

    /// `⌥Escape` gets you out. A bare `Escape` cannot: inside a terminal it belongs to
    /// whatever is running — vim, less, a REPL — and stealing it would make the terminal
    /// useless for exactly the people this is built for.
    private func installEscapeMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let isEscape = event.keyCode == 53
            if isEscape && event.modifierFlags.contains(.option) {
                self.hide()
                return nil
            }
            return event
        }
    }

    /// Pin to the bottom inner edge of Xcode's window. Called on every geometry change,
    /// so dragging or resizing Xcode carries the terminal with it.
    func dock() {
        guard let window, let axFrame = context?.focusedWindowFrame() else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let cocoa = NSRect(x: axFrame.minX,
                           y: primaryTop - axFrame.minY - axFrame.height,
                           width: axFrame.width,
                           height: axFrame.height)
        let inset: CGFloat = 1
        let height = (cocoa.height * heightFraction).rounded()
        window.setFrame(NSRect(x: cocoa.minX + inset,
                               y: cocoa.minY + inset,
                               width: cocoa.width - inset * 2,
                               height: height),
                        display: true)
    }
}
