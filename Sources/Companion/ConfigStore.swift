import AppKit
import XCommanderCore
import os

/// Finds the configuration files, reads them, watches them, and keeps the last good result.
///
/// Everything that decides what a file *means* lives in `XCommanderCore` and is tested without
/// a disk. This type is the part that cannot be: paths, file descriptors, and the debounce
/// around an editor that writes three times in a row. Keeping the split means the interesting
/// half is testable and this half is small enough to read.
///
/// **The last-good rule is enforced here.** `current` only ever holds a resolution that
/// resolved cleanly. A file with a typo in it updates `diagnostics` and leaves `current`
/// alone, so a user who saves a broken config keeps working with the keymap they had.
@MainActor
final class ConfigStore {

    /// `~/.config/xcommander/config.toml`, where this audience already keeps such things.
    static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".config/xcommander", directoryHint: .isDirectory)
    }

    static var globalFile: URL { directory.appending(path: "config.toml") }

    /// Committed in a repo, layered over the global file.
    static let projectFileName = ".xcommander.toml"

    /// Supplied by the app, because the project root follows Xcode's frontmost document.
    var projectRoot: () -> URL? = { nil }

    /// Called after every load that changed the live configuration.
    var onChange: ((ConfigResolution) -> Void)?

    /// The last resolution that was usable. Starts as the shipped keymap.
    private(set) var current: ConfigResolution

    /// What the most recent load had to say, good or bad. This is what the settings window
    /// and the menu bar report; it is *not* what is running.
    private(set) var diagnostics: [ConfigDiagnostic] = []

    private let registry: CommandRegistry
    private var fileWatch: DispatchSourceFileSystemObject?
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var debounce: Timer?
    private let log = Logger(subsystem: "dev.xcommander.XCommander", category: "config")

    init(registry: CommandRegistry) {
        self.registry = registry
        self.current = ConfigResolver.resolve([], blueprint: DefaultKeymap.blueprint,
                                              registry: registry)
    }

    // MARK: - loading

    func start() {
        load()
        watchDirectory()
        watchFile()
    }

    /// Re-read everything. Called on a file event, on `⌥RET q r`, and when Xcode moves to a
    /// project that may carry its own file.
    func load() {
        var sources: [ConfigSource] = []
        if let global = read(Self.globalFile) { sources.append(global) }
        if let root = projectRoot(),
           let project = read(root.appending(path: Self.projectFileName)) {
            sources.append(project)
        }

        let resolution = ConfigResolver.resolve(sources, blueprint: DefaultKeymap.blueprint,
                                                registry: registry)
        diagnostics = resolution.diagnostics

        for problem in resolution.diagnostics.forDisplay {
            log.notice("\(problem.description, privacy: .public)")
        }

        guard resolution.isUsable else {
            log.error("configuration not applied; keeping the last good one")
            return
        }

        current = resolution
        let names = sources.map(\.name).joined(separator: ", ")
        log.notice("configuration applied from \(names.isEmpty ? "defaults" : names, privacy: .public)")
        onChange?(resolution)
    }

    private func read(_ url: URL) -> ConfigSource? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ConfigSource(name: url.lastPathComponent, text: text)
    }

    // MARK: - watching

    /// Watching the **directory** as well as the file is not belt and braces.
    ///
    /// Most editors save by writing a temporary file and renaming it over the original, so
    /// the descriptor you were watching now points at a file nobody will ever touch again —
    /// a watcher on the file alone fires once and then goes quiet forever. The directory
    /// notices the rename, and it is also what notices a config file being created for the
    /// first time, which is every new user's first interaction with this feature.
    private func watchDirectory() {
        directoryWatch?.cancel()
        let descriptor = open(Self.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.watchFile()          // re-arm: the old descriptor may be orphaned
                self?.scheduleLoad()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directoryWatch = source
    }

    private func watchFile() {
        fileWatch?.cancel()
        fileWatch = nil
        let descriptor = open(Self.globalFile.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.watchFile()
                self?.scheduleLoad()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatch = source
    }

    /// One save can produce several events. Coalesce, or a reload runs three times and the
    /// log becomes useless for answering "did it pick up my change".
    private func scheduleLoad() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.load() }
        }
    }
}
