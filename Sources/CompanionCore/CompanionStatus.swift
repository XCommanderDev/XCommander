import Foundation

/// What the menu bar says. Derived, never stored — the same discipline as the editor's
/// dashboard: compute it from the inputs so it cannot drift out of date.
public enum CompanionStatus: Hashable, Sendable {
    /// No Accessibility permission. Nothing works and the user must be told why.
    case needsAccessibility
    /// Another app holds secure input, so the tap receives nothing, system-wide.
    /// Detectable only by polling — there is no notification. See `SPIKE-REPORT.md`.
    case pausedBySecureInput
    /// Running, but Xcode is not frontmost, so the leader key is passed through.
    case idle
    /// Xcode is frontmost and the leader key is live.
    case armed

    public static func derive(hasAccessibility: Bool,
                              secureInputActive: Bool,
                              xcodeFrontmost: Bool) -> CompanionStatus {
        if !hasAccessibility { return .needsAccessibility }
        if secureInputActive { return .pausedBySecureInput }
        return xcodeFrontmost ? .armed : .idle
    }

    /// The menu bar title. Short, because it sits next to the clock.
    public var menuBarSymbol: String {
        switch self {
        case .needsAccessibility: "exclamationmark.triangle"
        case .pausedBySecureInput: "lock.fill"
        case .idle: "keyboard"
        case .armed: "keyboard.fill"
        }
    }

    public var explanation: String {
        switch self {
        case .needsAccessibility:
            "Accessibility permission is needed to see the leader key."
        case .pausedBySecureInput:
            "Paused — another app has secure input enabled."
        case .idle:
            "Waiting for Xcode."
        case .armed:
            "Ready."
        }
    }
}
