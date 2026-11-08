import Foundation

/// Builds XCommander with SwiftPM and turns the result into a signed .app bundle.
///
/// Xcode does all of this when you press Run. Doing it by hand needs four steps: compile,
/// lay out the bundle (an `Info.plist`, the binary, the resources), compile the icons with
/// `actool`, and sign. Signing matters most: macOS ties the Accessibility permission to the
/// app's signature, so a stable signature means you grant the permission once.
struct AppBuilder {
    let project: Project
    let configuration: String

    let appName = "XCommander"
    /// The SwiftPM product that is the app's executable.
    let executable = "Companion"

    /// Outside ~/Documents on purpose: building under it adds extended attributes that make
    /// `codesign` fail with "resource fork, Finder information, or similar detritus".
    var buildRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/XCommander")
    }
    var appURL: URL { buildRoot.appending(path: "\(appName).app") }

    func build() throws {
        try shell("swift", "build", "-c", configuration, "--product", executable,
                  "--scratch-path", buildRoot.appending(path: ".build").path, in: project.root)
    }

    func bundle() throws {
        try build()
        let binary = buildRoot.appending(path: ".build/\(configuration)/\(executable)")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw Message("The build finished but there's no binary at \(binary.path).")
        }

        let contents = appURL.appending(path: "Contents")
        let resources = contents.appending(path: "Resources")
        let macOS = contents.appending(path: "MacOS")
        // Start Resources from scratch: actool names its output after the app icon, so an old
        // icon would otherwise stay behind next to the new one.
        try? FileManager.default.removeItem(at: resources)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        try infoPlist().write(to: contents.appending(path: "Info.plist"))
        let destination = macOS.appending(path: executable)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: binary, to: destination)

        // SwiftPM doesn't compile asset catalogues, so run the same tool Xcode uses. Without
        // it the app has no icon in the permission prompt and no menu bar mark.
        try shell("xcrun", "actool",
                  project.path("Sources/Companion/Assets.xcassets").path,
                  project.path("Sources/Companion/XCommanderAppIcon.icon").path,
                  "--compile", resources.path,
                  "--platform", "macosx", "--minimum-deployment-target", "14.0",
                  "--app-icon", "XCommanderAppIcon",
                  "--output-partial-info-plist", buildRoot.appending(path: "assets-partial.plist").path,
                  "--output-format", "human-readable-text", capture: true)

        try sign()
        print(appURL.path)
    }

    /// Signs with your Apple Development certificate if you have one, so the Accessibility
    /// permission survives rebuilds. Without one it signs ad hoc, and macOS will ask again
    /// after every build.
    private func sign() throws {
        try shell("xattr", "-cr", appURL.path, allowFailure: true)
        let identities = try shell("security", "find-identity", "-v", "-p", "codesigning", capture: true)
        let development = identities.split(separator: "\n")
            .first { $0.contains("Apple Development") }?
            .split(separator: " ").dropFirst().first.map(String.init)

        if let development {
            try shell("codesign", "--force", "--sign", development, "--options", "runtime",
                      "--timestamp=none", appURL.path, capture: true)
            print("Signed with your Apple Development certificate.")
        } else {
            try shell("codesign", "--force", "--sign", "-", appURL.path, capture: true)
            print("Signed ad hoc: no Apple Development certificate found, so macOS will ask for "
                  + "Accessibility permission again after each build.")
        }
    }

    func launch() throws {
        try shell("open", appURL.path)
        print("Launched.")
    }

    func stop() {
        _ = try? shell("osascript", "-e", "tell application \"\(appName)\" to quit",
                       capture: true, allowFailure: true)
        _ = try? shell("pkill", "-x", executable, capture: true, allowFailure: true)
    }

    func streamLogs() throws {
        try shell("log", "stream", "--level", "debug",
                  "--predicate", "subsystem == \"\(project.bundleIdentifier)\"")
    }

    private func infoPlist() throws -> Data {
        let info: [String: Any] = [
            "CFBundleName": appName,
            "CFBundleDisplayName": appName,
            "CFBundleIdentifier": project.bundleIdentifier,
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            // A menu-bar app: no Dock icon, no app switcher entry.
            "LSUIElement": true,
            "CFBundleIconFile": "XCommanderAppIcon",
            "CFBundleIconName": "XCommanderAppIcon",
            "NSHumanReadableCopyright": "Copyright © 2026 Wassim Mansouri. Licensed under GPLv3.",
        ]
        return try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    }
}
