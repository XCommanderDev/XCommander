import AppKit
import os
#if canImport(Sparkle)
import Sparkle
#endif

/// Keeps XCommander up to date, with Sparkle.
///
/// Once a day Sparkle reads the appcast at `SUFeedURL` (both keys are in project.yml). If it
/// lists a newer build, Sparkle shows the release notes and, when the user agrees, downloads
/// the DMG, checks it against `SUPublicEDKey` and the app's Developer ID, replaces the app and
/// relaunches it.
///
/// **Only in the app Xcode builds.** Sparkle is a dependency of the Xcode project, not of the
/// SwiftPM package, so a build made with `xcdev` has no Sparkle, `isAvailable` is false, and
/// there's nothing to turn on or off. Debug builds from Xcode have Sparkle but don't start it,
/// so nobody running from source is offered a download of what they're already building.
///
/// **Testers stay testers.** Someone running a prerelease (a version with a hyphen, like
/// `0.2.0-beta.1`) gets prereleases as well as final releases. Everyone else only gets final
/// releases. The appcast puts prereleases on a channel called `prerelease`, see
/// `allowedChannels(for:)`.
@MainActor
final class Updater: NSObject {

    /// Sparkle's own key for "check automatically". The Settings toggle is bound to it.
    static let automaticChecksKey = "SUEnableAutomaticChecks"

    /// Called with the version when an update was found in the background and is waiting for
    /// the user, so the menu can say so instead of a window popping up mid-keystroke.
    var onUpdateWaiting: ((_ version: String) -> Void)?
    /// Called when that update has been looked at, installed or dismissed.
    var onUpdateHandled: (() -> Void)?

    private let log = Logger(subsystem: "dev.xcommander.XCommander", category: "updates")

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    var isAvailable: Bool { true }
    #else
    var isAvailable: Bool { false }
    #endif

    func start() {
        #if canImport(Sparkle)
        Self.migrateOldSetting()
        #if DEBUG
        log.notice("updates are off in debug builds")
        #else
        controller.startUpdater()
        #endif
        #else
        log.notice("built without Sparkle: updates are off")
        #endif
    }

    /// Whether the menu offers "Check for Updates…". Only when the updater is actually running.
    var canCheckForUpdates: Bool {
        #if canImport(Sparkle) && !DEBUG
        controller.updater.canCheckForUpdates
        #else
        false
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        // A menu-bar app isn't active, and Sparkle's window would open behind Xcode.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }

    /// Called by Settings after the toggle changes `SUEnableAutomaticChecks`, so Sparkle
    /// reschedules its next check straight away.
    func setChecksAutomatically(_ on: Bool) {
        #if canImport(Sparkle)
        controller.updater.automaticallyChecksForUpdates = on
        #endif
    }

    /// 0.1.0-alpha.1 had its own update check with its own setting. Someone who turned that
    /// off shouldn't find updates switched back on.
    private static func migrateOldSetting() {
        let defaults = UserDefaults.standard
        guard let old = defaults.object(forKey: "checkForUpdates") as? Bool else { return }
        if !old { defaults.set(false, forKey: automaticChecksKey) }
        defaults.removeObject(forKey: "checkForUpdates")
    }
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {

    /// Prereleases are offered only to someone already running one.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return running.contains("-") ? ["prerelease"] : []
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // "You're up to date" also arrives here, as an error with a specific code.
        let code = (error as NSError).code
        if code != Int(SUError.noUpdateError.rawValue) {
            log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// **Gentle reminders.** XCommander is a menu-bar app that's rarely active, so an update window
/// appearing on its own would land in the middle of someone's typing in Xcode. Sparkle lets an
/// app like this show a quieter reminder instead: here, a line in the menu.
extension Updater: @preconcurrency SPUStandardUserDriverDelegate {

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show the window only when the check happened right after launch, when the
    /// user has just opened the app and a window is expected. Otherwise, the menu line.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        log.notice("update available: \(update.displayVersionString, privacy: .public)")
        if !handleShowingUpdate { onUpdateWaiting?(update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onUpdateHandled?()
    }

    func standardUserDriverWillFinishUpdateSession() {
        onUpdateHandled?()
    }
}
#endif
