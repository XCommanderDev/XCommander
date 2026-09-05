import Foundation
import CompanionCore
import os

/// Project-wide search, backed by ripgrep.
///
/// Xcode's own Find in Package works, but it is a navigator panel you drive with a mouse.
/// Running the search ourselves means the results land in the same picker as everything
/// else: type, see hits with their file and line, press Return to jump.
///
/// Two things make it feel live rather than laggy. The query is **debounced**, so typing
/// `PickerSession` starts one search rather than thirteen. And a search still running when
/// the next keystroke arrives is **killed**, because its answer is already stale — without
/// that, results from an older query arrive late and overwrite the newer ones.
@MainActor
final class ProjectSearch {

    /// Where `rg` is. Homebrew's path first, then the usual places.
    private static let candidates = [
        "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg", "/opt/local/bin/rg",
    ]
    static var executable: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Enough to fill several screens, few enough that a one-letter query does not try to
    /// render the whole codebase.
    private let limit = 200
    private let debounce: TimeInterval = 0.12

    private var running: Process?
    private var pending: Timer?
    private var generation = 0

    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "search")

    var isAvailable: Bool { Self.executable != nil }

    /// Search `root` for `query`, calling back on the main actor with the matches.
    /// Only the most recent call's results are delivered.
    func search(_ query: String, in root: URL,
                completion: @escaping @MainActor ([SearchMatch]) -> Void) {
        pending?.invalidate()
        cancel()

        // One and two characters match nearly everything and cost the most to render.
        guard query.count >= 2 else { completion([]); return }

        generation += 1
        let mine = generation
        let timer = Timer(timeInterval: debounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.run(query, in: root, generation: mine, completion: completion)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pending = timer
    }

    func cancel() {
        pending?.invalidate()
        pending = nil
        if let running, running.isRunning { running.terminate() }
        running = nil
    }

    private func run(_ query: String, in root: URL, generation mine: Int,
                     completion: @escaping @MainActor ([SearchMatch]) -> Void) {
        guard let executable = Self.executable else {
            log.error("ripgrep not found")
            completion([])
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "--json",
            "--smart-case",          // lower case matches anything, a capital means it
            "--max-count", "20",     // per file, so one noisy file cannot fill the list
            "--max-filesize", "2M",
            "--fixed-strings",       // a literal search: nobody types a regex by accident
            query,
            root.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        running = process

        // Read on a background queue: rg streams, and a large result set would otherwise
        // fill the pipe buffer and deadlock against a main thread waiting for exit.
        let child = process
        DispatchQueue.global(qos: .userInitiated).async {
            var matches: [SearchMatch] = []
            var carry = ""
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                carry += String(decoding: chunk, as: UTF8.self)
                // Keep the last, possibly incomplete, line for the next chunk.
                var lines = carry.components(separatedBy: "\n")
                carry = lines.removeLast()
                for line in lines {
                    if let match = RipgrepParser.parse(line: line) { matches.append(match) }
                }
                if matches.count >= self.limit { break }
            }
            if let match = RipgrepParser.parse(line: carry) { matches.append(match) }
            let capped = Array(matches.prefix(self.limit))

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if child.isRunning { child.terminate() }
                    // A late answer to a query the user has already moved past.
                    guard mine == self.generation else { return }
                    self.running = nil
                    completion(capped)
                }
            }
        }

        do { try process.run() } catch {
            log.error("could not run ripgrep: \(error.localizedDescription, privacy: .public)")
            completion([])
        }
    }

    /// Open a hit in Xcode at its line. `xed --line` is Xcode's own command-line tool, so
    /// this lands in the editor the user is already in rather than opening a new window.
    static func jump(to match: SearchMatch) {
        XcodeOpen.file(at: match.path, line: match.line)
    }
}
