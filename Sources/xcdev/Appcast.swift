import Foundation

/// Writes `appcast.xml`, the feed Sparkle reads to find out whether there's an update.
///
/// The feed is built from the published GitHub releases, so GitHub stays the one place where
/// releases live. A release appears in the feed when it has two assets, both uploaded by the
/// release workflow:
///
/// - `XCommander.dmg`, the download;
/// - `sparkle-update.json`, what the feed needs to know about it that GitHub doesn't: the build
///   number Sparkle compares versions with, and the EdDSA signature Sparkle checks the
///   download against.
///
/// Prereleases go on the `prerelease` channel, which only people already running a
/// prerelease listen to (see `Updater.allowedChannels(for:)` in the app). Drafts are left out.
///
/// The Appcast workflow runs this whenever a release is published, edited or deleted, and
/// serves the result with GitHub Pages. To look at the feed locally:
///
///     swift run xcdev appcast /tmp/appcast.xml
struct Appcast {
    let repository = "XCommanderDev/XCommander"
    /// Enough history for anyone a few releases behind; Sparkle only needs the newest.
    let maximumItems = 20

    struct Release: Decodable {
        let name: String?
        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
        let bodyHTML: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case name, draft, prerelease, assets
            case tagName = "tag_name", htmlURL = "html_url"
            case publishedAt = "published_at", bodyHTML = "body_html"
        }
    }

    struct Asset: Decodable {
        let name: String
        let size: Int
        let downloadURL: String
        enum CodingKeys: String, CodingKey { case name, size, downloadURL = "browser_download_url" }
    }

    /// Written by the release workflow next to the DMG.
    struct UpdateInfo: Decodable {
        let version: String
        let build: String
        let edSignature: String
        let length: Int
        let minimumSystemVersion: String
    }

    func write(to output: URL) throws {
        let releases = try fetchReleases()
            .filter { !$0.draft }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }

        var items: [String] = []
        for release in releases where items.count < maximumItems {
            guard let dmg = release.assets.first(where: { $0.name == "XCommander.dmg" }),
                  let info = release.assets.first(where: { $0.name == "sparkle-update.json" }) else {
                print("skipping \(release.tagName): no sparkle-update.json")
                continue
            }
            let update = try JSONDecoder().decode(UpdateInfo.self, from: get(info.downloadURL))
            guard update.length == dmg.size else {
                throw Message("\(release.tagName): the DMG is \(dmg.size) bytes but was signed at "
                              + "\(update.length). Was it replaced after the release was built?")
            }
            items.append(item(release, dmg: dmg, update: update))
            print("added \(release.tagName) (build \(update.build))")
        }

        let feed = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <title>XCommander</title>
                <link>https://xcommander.dev</link>
                <description>Updates for XCommander</description>
                <language>en</language>
            \(items.joined(separator: "\n"))
              </channel>
            </rss>

            """
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try feed.write(to: output, atomically: true, encoding: .utf8)
        print("wrote \(output.path) with \(items.count) release(s)")
    }

    private func item(_ release: Release, dmg: Asset, update: UpdateInfo) -> String {
        let title = release.name ?? "XCommander \(update.version)"
        let date = release.publishedAt.map(Self.rfc822.string(from:)) ?? ""
        let channel = release.prerelease ? "\n      <sparkle:channel>prerelease</sparkle:channel>" : ""
        // GitHub's own rendering of the release notes. "]]>" would end the CDATA section early.
        let notes = (release.bodyHTML ?? "").replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
        return """
                <item>
                  <title>\(escape(title))</title>
                  <link>\(escape(release.htmlURL))</link>
                  <pubDate>\(date)</pubDate>
                  <sparkle:version>\(escape(update.build))</sparkle:version>
                  <sparkle:shortVersionString>\(escape(update.version))</sparkle:shortVersionString>
                  <sparkle:minimumSystemVersion>\(escape(update.minimumSystemVersion))</sparkle:minimumSystemVersion>\(channel)
                  <description><![CDATA[\(notes)]]></description>
                  <enclosure url="\(escape(dmg.downloadURL))" length="\(dmg.size)" type="application/octet-stream" sparkle:edSignature="\(escape(update.edSignature))"/>
                </item>
            """
    }

    private func fetchReleases() throws -> [Release] {
        let data = try get("https://api.github.com/repos/\(repository)/releases?per_page=100",
                           accept: "application/vnd.github.html+json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
    }

    /// A blocking GET, which is all a one-shot command-line tool needs. Uses `GITHUB_TOKEN`
    /// when it's set (it is in GitHub Actions), which lifts the API's rate limit.
    private func get(_ address: String, accept: String? = nil) throws -> Data {
        guard let url = URL(string: address) else { throw Message("Not a URL: \(address)") }
        var request = URLRequest(url: url)
        request.setValue("xcdev", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !token.isEmpty,
           url.host == "api.github.com" {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        nonisolated(unsafe) var result: Result<Data, any Error> = .failure(Message("No response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                result = .failure(Message("GET \(address) answered \(status)"))
            } else {
                result = .success(data ?? Data())
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
