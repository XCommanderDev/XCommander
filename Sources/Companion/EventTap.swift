import AppKit
import Carbon
import CoreGraphics
import CompanionCore
import os

/// The `CGEventTap`, and the three ways it fails in practice.
///
/// 1. **Disabled on timeout.** macOS disables a tap whose callback is slow and sends
///    `.tapDisabledByTimeout`. Handle it on the same callback and re-enable, or the app
///    silently stops working after one stall.
/// 2. **Secure input.** While any app holds it the tap receives nothing, system-wide. It
///    is *starvation*, not disabling: no callback fires and `CGEvent.tapIsEnabled` stays
///    true, so that flag cannot detect it. Recovery is automatic. Polling
///    `IsSecureEventInputEnabled()` is the only detection there is.
/// 3. **A slow callback.** Every microsecond here is on the user's keystroke path, so the
///    callback decides swallow-or-pass and returns. It never asks the system anything.
@MainActor
final class EventTap {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?

    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "tap")

    /// Asked for every key press. Returns true to swallow it.
    private let handler: (CGKeyCode, CGEventFlags) -> Bool
    /// Called when the tap is starved or disabled, so a half-typed sequence is abandoned
    /// rather than left hanging.
    private let onInterrupted: () -> Void
    private let onSecureInputChanged: (Bool) -> Void

    private(set) var secureInputActive = IsSecureEventInputEnabled()
    private(set) var reEnableCount = 0

    init(handler: @escaping (CGKeyCode, CGEventFlags) -> Bool,
         onInterrupted: @escaping () -> Void,
         onSecureInputChanged: @escaping (Bool) -> Void) {
        self.handler = handler
        self.onInterrupted = onInterrupted
        self.onSecureInputChanged = onSecureInputChanged
    }

    var isInstalled: Bool { tap != nil }

    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            // Pull the plain value types out of the event *before* crossing into the
            // actor: `CGEvent` and `Unmanaged<CGEvent>` are not Sendable, but a keycode
            // and a flags mask are, so nothing non-Sendable has to cross at all.
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            // The run loop source is added to the *main* run loop below, so this callback
            // runs on the main thread. Asserting that is what lets it touch main-actor
            // state without a hop, and a hop is exactly what it must not do.
            let swallow = MainActor.assumeIsolated {
                let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.handle(type: type, keyCode: keyCode, flags: flags)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate returned nil — Accessibility permission is missing")
            return false
        }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        startHealthPolling()
        return true
    }

    func uninstall() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
    }

    /// Returns true when the key should be swallowed.
    private func handle(type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                reEnableCount += 1
                log.notice("tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabled")
            }
            onInterrupted()
            return true
        }
        return handler(keyCode, flags)
    }

    /// One poll, doing two jobs.
    ///
    /// There is no notification for secure input, so it has to be asked for. 250 ms catches
    /// both edges within one interval and costs nothing measurable.
    ///
    /// The same tick also checks whether the tap is still enabled. This is belt-and-braces
    /// rather than a fix for anything observed: the callback already re-enables on
    /// `.tapDisabledByTimeout`, and secure input does *not* disable a tap — it starves it,
    /// with `tapIsEnabled` staying true throughout and delivery resuming on its own. The
    /// poll exists because the callback is otherwise the only place re-enabling happens, so
    /// a tap disabled by any route that does not call back would stay dead. It has never
    /// fired in practice.
    private func startHealthPolling() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                let secure = IsSecureEventInputEnabled()
                if secure != self.secureInputActive {
                    self.secureInputActive = secure
                    if secure { self.onInterrupted() }
                    self.onSecureInputChanged(secure)
                }

                guard let tap = self.tap else { return }
                if !CGEvent.tapIsEnabled(tap: tap) {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    self.reEnableCount += 1
                    self.onInterrupted()
                    self.log.notice("tap found disabled by poll, re-enabled")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }
}
