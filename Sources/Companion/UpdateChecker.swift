import AppKit
import XCommanderCore
import os

/// Asks GitHub once a day whether a newer release of XCommander exists.
///
/// It never downloads or installs anything: when there's a newer release it tells the menu
/// bar, which offers a link to the release page. Which release counts as newer is decided by
/// `UpdateCheck` in Core, where it's tested: people running a prerelease are offered newer
/// prereleases, people running a final release only final releases.
///
/// Off in debug builds, so nobody running from source is told to download what they're
/// already building. Can be turned off in Settings.
@MainActor
final class UpdateChecker {

    static let releasesAPI = URL(string: "https://api.github.com/repos/XCommanderDev/XCommander/releases?per_page=30")!

    /// Called with the version and its release page when there's something newer.
    var onUpdateAvailable: ((_ version: String, _ page: URL) -> Void)?

    private var timer: Timer?
    private let log = Logger(subsystem: "dev.xcommander.XCommander", category: "updates")

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    func start() {
        #if DEBUG
        log.notice("update checks are off in debug builds")
        #else
        // A minute after launch rather than straight away: at login the network may not be up
        // yet, and nothing about an update is urgent.
        let first = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        let daily = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(first, forMode: .common)
        RunLoop.main.add(daily, forMode: .common)
        timer = daily
        #endif
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url", draft }
    }

    func check() {
        guard SettingsWindow.checksForUpdates else { return }
        var request = URLRequest(url: Self.releasesAPI)
        // GitHub's API asks every client to say who it is.
        request.setValue("XCommander/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let current = currentVersion

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    log.notice("update check: GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    return
                }
                let releases = try JSONDecoder().decode([Release].self, from: data).filter { !$0.draft }
                guard let tag = UpdateCheck.newest(in: releases.map(\.tagName), current: current),
                      let release = releases.first(where: { $0.tagName == tag }) else { return }
                let version = ReleaseVersion(tag)?.description ?? tag
                log.notice("update available: \(version, privacy: .public)")
                onUpdateAvailable?(version, release.htmlURL)
            } catch {
                log.notice("update check failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
