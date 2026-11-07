import Foundation

/// One running copy of Xcode, as far as choosing between them is concerned.
///
/// No AppKit here: the app turns each `NSRunningApplication` into one of these, so the rule
/// that picks a process can be tested without a process.
public struct XcodeInstance: Hashable, Sendable {
    public var pid: Int32
    public var bundlePath: String
    public var isActive: Bool
    public var launchDate: Date?

    public init(pid: Int32, bundlePath: String, isActive: Bool, launchDate: Date? = nil) {
        self.pid = pid
        self.bundlePath = bundlePath
        self.isActive = isActive
        self.launchDate = launchDate
    }
}

/// Which Xcode to talk to when more than one is running.
///
/// **Every Xcode has the bundle identifier `com.apple.dt.Xcode`** — the release, every beta,
/// and any copy renamed in `/Applications`. So "the running Xcode" is not one process, and
/// `runningApplications(withBundleIdentifier:).first` is a coin toss: with a release and a
/// beta both open, the leader can be typed into one while its menu items are pressed in the
/// other, and a scan of one gets recorded as the menus of the other.
///
/// The rule, in order:
///   1. The one in front. That is where the user's keystrokes are going.
///   2. The one that was last in front, if it is still running. Switching to Terminal must
///      not move the app's attention to a different Xcode.
///   3. The most recently launched, so a fresh beta wins over a release left open for days.
///
/// One function decides, and everything that touches Xcode asks it — the context, the window
/// tracker, the scanner and `xcmdr` — so the app can never be watching one Xcode and pressing
/// another.
public enum XcodeTarget {

    public static func choose(_ running: [XcodeInstance], lastActive: Int32? = nil) -> XcodeInstance? {
        if let active = running.first(where: \.isActive) { return active }
        if let lastActive, let previous = running.first(where: { $0.pid == lastActive }) {
            return previous
        }
        return running.max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
    }
}
