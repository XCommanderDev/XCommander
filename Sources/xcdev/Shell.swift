import Foundation

struct CommandFailed: Error, CustomStringConvertible {
    let command: [String]
    let status: Int32
    var description: String { "\(command.joined(separator: " ")) exited with status \(status)" }
}

/// Runs a command-line tool and waits for it to finish.
///
/// The tool's output goes straight to the terminal unless `capture` is set, in which case it's
/// returned instead. A non-zero exit status throws, unless `allowFailure` is set.
@discardableResult
func shell(_ arguments: String..., in directory: URL? = nil,
           capture: Bool = false, allowFailure: Bool = false) throws -> String {
    try shell(arguments, in: directory, capture: capture, allowFailure: allowFailure)
}

@discardableResult
func shell(_ arguments: [String], in directory: URL? = nil,
           capture: Bool = false, allowFailure: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    if let directory { process.currentDirectoryURL = directory }

    let pipe = Pipe()
    if capture {
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
    }
    try process.run()
    // Read before waiting: a tool that writes a lot would otherwise block on a full pipe.
    let output = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    process.waitUntilExit()

    if process.terminationStatus != 0 && !allowFailure {
        throw CommandFailed(command: arguments, status: process.terminationStatus)
    }
    return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Whether a command-line tool is installed, for a friendlier message than "not found".
func isInstalled(_ tool: String) -> Bool {
    (try? shell("which", tool, capture: true, allowFailure: true))?.isEmpty == false
}

/// The repository, found from the current directory, plus the settings shared by every command.
struct Project {
    let root: URL

    static func locate() throws -> Project {
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appending(path: "project.yml").path),
               FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path) {
                return Project(root: directory)
            }
            directory.deleteLastPathComponent()
        }
        throw Message("Run this from inside the XCommander repository.")
    }

    func path(_ relative: String) -> URL { root.appending(path: relative) }

    /// The bundle ID, built the same way the Xcode project builds it: `BUNDLE_ID_PREFIX` from
    /// `Config/Signing.local.xcconfig` if you have one, otherwise from `Config/Signing.xcconfig`.
    var bundleIdentifier: String {
        let prefix = xcconfigValue("BUNDLE_ID_PREFIX", in: "Config/Signing.local.xcconfig")
            ?? xcconfigValue("BUNDLE_ID_PREFIX", in: "Config/Signing.xcconfig")
            ?? "dev.xcommander"
        return "\(prefix).XCommander"
    }

    private func xcconfigValue(_ key: String, in file: String) -> String? {
        guard let text = try? String(contentsOf: path(file), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == key, !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }
}

struct Message: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
