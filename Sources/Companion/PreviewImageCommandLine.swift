import AppKit
import AutographeCore
import Foundation

/// `Autographe --preview-image <file> <out.png> [line]` — the picker panel, rendered offscreen.
///
/// The panel is borderless, ignores the mouse, sits above everything and vanishes on Escape.
/// That makes it the hardest surface in the app to *look* at, and design work needs looking.
/// This draws the real `PickerView` — same code, same fonts, same palette — into a bitmap, so
/// spacing, colour and truncation can be judged without driving Xcode or the event tap.
///
/// It also keeps the promise the rest of this app's command-line modes make: it is the same
/// code the app runs, so what it shows cannot drift from what ships.
@MainActor
enum PreviewImageCommandLine {

    static func run(path: String, output: String, line: Int?, dark: Bool) -> Bool {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Pinned rather than inherited: the whole point of looking is to see both, and a
        // render that quietly followed the machine's setting would only ever show one.
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            return false
        }
        let bytes = [UInt8](data)
        let lines = LineTable(bytes: bytes)
        let parsed = SourceKit.shared.parse(path: path, lines: lines, bytes: bytes)

        let previewWidth: CGFloat = 620
        let view = PickerView(frame: NSRect(x: 0, y: 0,
                                            width: PickerOverlay.listWidth + previewWidth,
                                            height: PickerOverlay.panelHeight))
        view.previewWidth = previewWidth

        // A plausible list to sit above the pane: the rows the picker would show for this file.
        let name = (path as NSString).lastPathComponent
        var session = PickerSession(title: line == nil ? "Files" : "Search Project", items: [
            PickerItem(id: "file:\(path)", title: name,
                       detail: (path as NSString).deletingLastPathComponent, icon: .file),
            PickerItem(id: "file:/other/Keymap.swift", title: "Keymap.swift",
                       detail: "Sources/AutographeCore", icon: .file),
            PickerItem(id: "file:/other/Picker.swift", title: "Picker.swift",
                       detail: "Sources/AutographeCore", icon: .file),
        ])
        session.pageSize = 8
        view.session = session

        // Through the same decision the loader makes, so what this shows cannot drift from
        // what the app draws.
        let source = PreviewBuilder.Source(lines: lines, bytes: bytes,
                                           tokens: parsed?.tokens ?? [],
                                           outline: parsed?.outline ?? [],
                                           isSource: SourceKit.canParse(path))
        // A stand-in for the searched term, so the mark can be judged: the first run of
        // non-space characters on the focus line.
        var highlight: Range<Int>?
        if let line, let range = lines.byteRange(ofLine: line, in: bytes) {
            let raw = Array(bytes[range])
            if let from = raw.firstIndex(where: { $0 != 0x20 && $0 != 0x09 }) {
                let to = raw[from...].firstIndex(where: { $0 == 0x20 }) ?? raw.count
                highlight = from..<to
            }
        }
        let request: PreviewRequest = line == nil
            ? .outline(path: path)
            : .text(path: path, focusLine: line, highlight: highlight)
        view.preview = PreviewBuilder.body(for: request, from: source,
                                           capacity: view.previewLineCapacity,
                                           columns: view.previewColumnCapacity)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        // The panel's material is not part of the view, so stand in for it: the pane is judged
        // against the colour it will actually sit on.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        Theme.pickerBackground.withAlphaComponent(1).setFill()
        view.bounds.fill()
        NSGraphicsContext.restoreGraphicsState()

        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: NSBitmapImageRep.FileType.png,
                                           properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: output))
            print("wrote \(output)  \(Int(view.bounds.width))×\(Int(view.bounds.height))"
                  + (dark ? "  dark" : "  light"))
            return true
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return false
        }
    }
}
