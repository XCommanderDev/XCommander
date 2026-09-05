import AppKit
import ApplicationServices
import os

/// Watches Xcode's focused window so the overlays can follow it.
///
/// `AXObserver` rather than a poll. Reading the frame costs p50 452 µs and p99 28 ms, which
/// is far too much to do on a timer, and the notifications arrive first anyway: measured
/// during the spikes, `AXWindowMoved` beat a 100 ms poll by ~30 ms every time.
///
/// The observers are registered on the *window element*, so they have to be re-registered
/// whenever the focused window changes — and on the app element, which is how we learn that
/// it did.
@MainActor
final class WindowTracker {

    /// Called when the window moved, resized, or a different one took focus.
    var onGeometryChanged: (() -> Void)?
    /// Called when the file in the focused editor changed.
    var onDocumentChanged: ((URL?) -> Void)?

    private var observer: AXObserver?
    private var observedWindow: AXUIElement?
    private var pid: pid_t?
    private var documentTimer: Timer?
    private var lastDocument: URL?

    private let context: XcodeContext
    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "tracker")

    init(context: XcodeContext) {
        self.context = context
    }

    func start() {
        stop()
        guard let xcode = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").first else { return }
        pid = xcode.processIdentifier

        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            MainActor.assumeIsolated {
                let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
                tracker.handle(notification as String)
            }
        }
        var created: AXObserver?
        guard AXObserverCreate(xcode.processIdentifier, callback, &created) == .success,
              let created else { return }
        observer = created

        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification,
                     kAXApplicationActivatedNotification,
                     kAXFocusedUIElementChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observeFocusedWindow()

        // The open document has no notification of its own, so this one is a poll. It is
        // slow on purpose: it feeds the buffer list, and nothing about it is urgent.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDocument() }
        }
        RunLoop.main.add(timer, forMode: .common)
        documentTimer = timer
    }

    func stop() {
        documentTimer?.invalidate()
        documentTimer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedWindow = nil
    }

    private func handle(_ notification: String) {
        if notification == kAXFocusedWindowChangedNotification as String
            || notification == kAXApplicationActivatedNotification as String {
            // A different window means different move/resize notifications to listen to.
            observeFocusedWindow()
        }
        if notification == kAXFocusedUIElementChangedNotification as String {
            checkDocument()
        }
        onGeometryChanged?()
    }

    /// Move the window-level observers onto whatever window is focused now.
    private func observeFocusedWindow() {
        guard let observer, let pid else { return }
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              CFGetTypeID(win!) == AXUIElementGetTypeID() else { return }
        let window = win as! AXUIElement

        if let previous = observedWindow {
            for name in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
                AXObserverRemoveNotification(observer, previous, name as CFString)
            }
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
        observedWindow = window
    }

    private func checkDocument() {
        let current = context.documentURL()
        guard current != lastDocument else { return }
        lastDocument = current
        onDocumentChanged?(current)
    }
}
