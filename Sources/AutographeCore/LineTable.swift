import Foundation

/// Where the lines of a file start, in **bytes**.
///
/// Two things need this and they need it to agree. The preview shows a window of lines, and
/// sourcekitd places every syntax token and every declaration at a **UTF-8 byte offset** into
/// the file. Converting between the two by counting `Character`s is the bug that shows up the
/// first time someone previews a file with an accent or an emoji in it: Swift's `String` index
/// is not a byte offset, and the token lands on the wrong glyph.
///
/// So the file is held as bytes, split as bytes, and decoded one line at a time only when a
/// line is actually drawn.
public struct LineTable: Hashable, Sendable {

    /// Byte offset of the first character of each line. Always starts at 0 for a non-empty file.
    public let lineStarts: [Int]
    public let byteCount: Int

    /// 1-based, and **no phantom last line**: a file ending in a newline has as many lines as
    /// it has newlines, not one more. Getting this wrong makes every window arithmetic drift
    /// by one at the end of well-formed files, which is most of them.
    public var lineCount: Int { lineStarts.count }

    public init(bytes: [UInt8]) {
        byteCount = bytes.count
        guard !bytes.isEmpty else { lineStarts = []; return }
        var starts = [0]
        for (i, byte) in bytes.enumerated() where byte == 0x0A {
            let next = i + 1
            // The newline that ends the file does not open another line.
            if next < bytes.count { starts.append(next) }
        }
        lineStarts = starts
    }

    /// The 1-based line containing a byte offset, clamped rather than optional: sourcekitd
    /// occasionally reports an offset at the very end of the buffer, and a preview that
    /// returns nil there would drop a token for no reason the user could understand.
    public func line(atByteOffset offset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        guard offset > 0 else { return 1 }
        // Binary search for the last start <= offset.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// Byte range of a 1-based line, **excluding** its terminator, so a drawn line never
    /// carries a trailing newline or a stray `\r`.
    public func byteRange(ofLine line: Int, in bytes: [UInt8]) -> Range<Int>? {
        guard line >= 1, line <= lineCount else { return nil }
        let start = lineStarts[line - 1]
        var end = line < lineCount ? lineStarts[line] - 1 : byteCount
        // The last line of a file that ends in a newline owns that newline as its
        // terminator, and a drawn line must not carry it.
        if end > start, end <= bytes.count, bytes[end - 1] == 0x0A { end -= 1 }
        // A CRLF file then leaves the carriage return at the end of the content.
        if end > start, end <= bytes.count, bytes[end - 1] == 0x0D { end -= 1 }
        return start..<max(start, end)
    }

    /// Decode a run of lines, replacing anything undecodable rather than failing the preview.
    public func text(ofLines range: ClosedRange<Int>, in bytes: [UInt8]) -> [String] {
        range.compactMap { line in
            guard let r = byteRange(ofLine: line, in: bytes) else { return nil }
            return String(decoding: bytes[r], as: UTF8.self)
        }
    }
}
