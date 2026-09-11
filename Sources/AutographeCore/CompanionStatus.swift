import Foundation

/// What the menu bar says. Derived, never stored — the same discipline as the editor's
/// dashboard: compute it from the inputs so it cannot drift out of date.
public enum CompanionStatus: Hashable, Sendable {
    /// No Accessibility permission. Nothing works and the user must be told why.
    case needsAccessibility
    /// Switched off from the menu. Deliberate, so it says so rather than looking broken.
    case disabled
    /// Another app holds secure input, so the tap receives nothing, system-wide.
    /// Detectable only by polling — there is no notification. See `SPIKE-REPORT.md`.
    case pausedBySecureInput
    /// Running, but Xcode is not frontmost, so the leader key is passed through.
    case idle
    /// Xcode is frontmost and the leader key is live.
    case armed

    public static func derive(hasAccessibility: Bool,
                              secureInputActive: Bool,
                              xcodeFrontmost: Bool,
                              enabled: Bool = true) -> CompanionStatus {
        if !hasAccessibility { return .needsAccessibility }
        if !enabled { return .disabled }
        if secureInputActive { return .pausedBySecureInput }
        return xcodeFrontmost ? .armed : .idle
    }

    /// The SF Symbol to draw in the menu bar when something is *wrong*, or `nil` when the
    /// state is ordinary and the brand mark speaks for itself.
    ///
    /// Only the two fault states have one. A dimmed brand mark is a poor way to say "your
    /// keyboard has stopped working"; a warning triangle is the shape the user already reads
    /// as "this needs you", and being a template image it tints with the menu bar.
    public var faultSymbol: String? {
        switch self {
        case .needsAccessibility: "exclamationmark.triangle.fill"
        case .pausedBySecureInput: "lock.fill"
        case .disabled, .idle, .armed: nil
        }
    }

    public var explanation: String {
        switch self {
        case .needsAccessibility:
            "Accessibility permission is needed to see the leader key."
        case .disabled:
            "Leader key disabled."
        case .pausedBySecureInput:
            "Paused — another app has secure input enabled."
        case .idle:
            "Waiting for Xcode."
        case .armed:
            "Ready."
        }
    }
}
