import AutographeCore
import Foundation

/// `Autographe --preview <file> [line]` — what the preview pane would show, as text.
///
/// Here for the same reason `--check` is: **it must be the same code the app runs.** The pane
/// is drawn in a borderless panel that ignores the mouse and vanishes on Escape, which is the
/// worst surface on the machine to debug a byte-offset bug on. This prints the identical
/// parse — the same `LineTable`, the same `SourceKit.parse` — where it can be read, diffed and
/// pasted into a bug report.
///
/// It also earns its keep on the day sourcekitd changes: one command says whether the tokens
/// and the outline still come back.
enum PreviewCommandLine {

    static func run(path: String, line: Int?) -> Bool {
        guard let bytes = FileManager.default.contents(atPath: path).map({ [UInt8]($0) }) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            return false
        }
        let table = LineTable(bytes: bytes)
        let started = Date()
        let parsed = SourceKit.shared.parse(path: path, lines: table, bytes: bytes)
        let ms = Date().timeIntervalSince(started) * 1000

        print("file      \(path)")
        print("lines     \(table.lineCount)  (\(bytes.count) bytes)")
        print("sourcekit \(SourceKit.shared.isLoaded ? "loaded" : "unavailable") — \(String(format: "%.1f", ms)) ms")

        guard let parsed else {
            print("\nno parse: preview would fall back to plain text")
            printWindow(table: table, bytes: bytes, line: line, tokens: [])
            return true
        }

        var byRole: [SyntaxRole: Int] = [:]
        for token in parsed.tokens { byRole[token.role, default: 0] += 1 }
        print("tokens    \(parsed.tokens.count)  " + byRole.sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: " "))

        print("\noutline")
        if parsed.outline.isEmpty {
            print("  (none)")
        }
        for (node, depth) in OutlineNode.flatten(parsed.outline) {
            let indent = String(repeating: "  ", count: depth + 1)
            let access = node.isPublic ? "+" : " "
            print("\(indent)\(access) \(node.icon.glyph.padding(toLength: 2, withPad: " ", startingAt: 0))"
                  + " \(node.name)  \(node.kind.label)  :\(node.line)"
                  + (node.summary.map { "\n\(indent)     — \($0)" } ?? ""))
        }

        printWindow(table: table, bytes: bytes, line: line, tokens: parsed.tokens)
        return true
    }

    /// The window the pane would draw, with a marker in the gutter on the focus line and the
    /// syntax roles spelled out under it — the text form of what the panel paints.
    private static func printWindow(table: LineTable, bytes: [UInt8], line: Int?,
                                    tokens: [SyntaxToken]) {
        let window = PreviewWindow.around(line: line, total: table.lineCount, capacity: 16)
        guard let last = window.lastLine else { return }
        print("\nwindow    lines \(window.firstLine)–\(last) of \(table.lineCount)"
              + (line.map { ", focus \($0)" } ?? ", no focus"))

        var rolesByLine: [Int: [SyntaxRole]] = [:]
        for token in tokens {
            rolesByLine[table.line(atByteOffset: token.offset), default: []].append(token.role)
        }
        for (offset, text) in table.text(ofLines: window.firstLine...last, in: bytes).enumerated() {
            let number = window.firstLine + offset
            let marker = number == line ? "▸" : " "
            let roles = rolesByLine[number].map { Set($0).map(\.rawValue).sorted().joined(separator: ",") }
            print(String(format: "%@ %5d │ %@", marker, number, text)
                  + (roles.map { "   ⟨\($0)⟩" } ?? ""))
        }
    }
}
