import Foundation
import CompanionCore

/// The files you have actually been editing, most recent first.
///
/// This is the buffer list, and we keep it ourselves because Xcode will not lend us one.
/// Its window has no tab attribute, and the `Window` menu lists *windows*, not the files
/// open in them — so the honest source is to watch which document has focus and remember.
/// That also makes it better than a tab list: it is the files you have been in, in the
/// order you were last in them, which is what `SPC ,` is for.
@MainActor
final class DocumentHistory {

    private struct Visit: Codable {
        var path: String
        var last: Date
    }

    private var visits: [Visit] = []
    private let limit = 60
    private let defaultsKey = "documentHistory"

    init() { load() }

    /// The file currently focused, so the picker can exclude it: switching to where you
    /// already are is not a switch.
    private(set) var current: URL?

    func record(_ url: URL?) {
        guard let url, url.isFileURL else { current = url; return }
        // A workspace window's `AXDocument` is the *package directory* when a Package.swift
        // is opened as a package, not a file. A directory is not a buffer.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        current = url
        let path = url.path
        visits.removeAll { $0.path == path }
        visits.insert(Visit(path: path, last: Date()), at: 0)
        if visits.count > limit { visits.removeLast(visits.count - limit) }
        save()
    }

    /// Rows for the buffer picker: everything visited except the file you are in, and
    /// nothing that has since been deleted.
    var items: [PickerItem] {
        let fm = FileManager.default
        return visits.compactMap { visit in
            guard visit.path != current?.path, fm.fileExists(atPath: visit.path) else { return nil }
            let url = URL(fileURLWithPath: visit.path)
            return PickerItem(id: "file:" + visit.path,
                              title: url.lastPathComponent,
                              detail: url.deletingLastPathComponent().lastPathComponent)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Visit].self, from: data) else { return }
        visits = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(visits) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
