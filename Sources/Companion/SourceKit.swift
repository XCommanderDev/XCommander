import XCommanderCore
import CSourceKit
import Foundation
import os

/// `sourcekitd`, the parser Xcode itself uses, loaded out of whichever Xcode is selected.
///
/// **Why this and not a tokenizer of our own.** A hand-rolled Swift lexer is days of work and
/// approximate for ever. This is the real one, it ships inside Xcode, and a *syntactic-only*
/// `editor.open` needs no compiler arguments, no build settings and no index — it is a parse of
/// one file. Measured at **0.51 ms** median on a 151-line file against a ~60 ms debounce budget
/// (`PREVIEW-SPIKE.md`), so colour in the preview costs nothing worth counting.
///
/// **And it hands back the outline in the same response.** `key.substructure` is a nested
/// declaration tree carrying each declaration's name, accessibility and *documentation*. So one
/// request answers both questions the preview pane asks, and the file outline needs no index —
/// it works on a file that has never been built.
///
/// Nothing here is linked. Every entry point is `dlsym`ed through the typedefs in
/// `sourcekitd_shim.h`, so a missing, moved or older Xcode costs the preview and nothing else.
///
/// **Loaded lazily, once, off the main thread.** The dylib is 169 MB and the first `dlopen`
/// measured 129 ms; that is fine on a first preview and unacceptable at launch for a menu-bar
/// app that is otherwise invisible.
final class SourceKit: @unchecked Sendable {

    static let shared = SourceKit()

    private let log = Logger(subsystem: "dev.xcommander.XCommander", category: "preview")
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var didAttemptLoad = false

    private var fromYAML: sk_request_create_from_yaml_t?
    private var send: sk_send_request_sync_t?
    private var releaseRequest: sk_request_release_t?
    private var disposeResponse: sk_response_dispose_t?
    private var isError: sk_response_is_error_t?
    private var responseValue: sk_response_get_value_t?
    private var uidFromCStr: sk_uid_get_from_cstr_t?
    private var uidString: sk_uid_get_string_ptr_t?
    private var dictValue: sk_variant_dictionary_get_value_t?
    private var dictUID: sk_variant_dictionary_get_uid_t?
    private var dictInt: sk_variant_dictionary_get_int64_t?
    private var dictString: sk_variant_dictionary_get_string_t?
    private var arrayCount: sk_variant_array_get_count_t?
    private var arrayValue: sk_variant_array_get_value_t?
    private var variantType: sk_variant_get_type_t?

    /// Interned once: sourcekitd hands out a stable pointer per key name.
    private var uids: [String: sourcekitd_uid_t] = [:]

    private init() {}

    var isLoaded: Bool { lock.withLock { handle != nil } }

    /// Resolve the framework inside the *selected* Xcode, so a developer on a beta toolchain
    /// gets that one rather than whatever was hard-coded.
    private static func libraryPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let developer = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !developer.isEmpty else { return nil }
        let path = developer
            + "/Toolchains/XcodeDefault.xctoolchain/usr/lib"
            + "/sourcekitdInProc.framework/Versions/A/sourcekitdInProc"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Load, once. Safe to call from any thread; call it from a background one.
    @discardableResult
    func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didAttemptLoad { return handle != nil }
        didAttemptLoad = true

        guard let path = Self.libraryPath() else {
            log.notice("no sourcekitd in the selected Xcode; preview falls back to plain text")
            return false
        }
        let started = Date()
        guard let opened = dlopen(path, RTLD_LAZY) else {
            log.error("dlopen sourcekitd failed: \(String(cString: dlerror()), privacy: .public)")
            return false
        }
        handle = opened

        func sym<T>(_ name: String) -> T? {
            guard let p = dlsym(opened, name) else {
                log.error("sourcekitd is missing \(name, privacy: .public)")
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }
        guard let initialize: sk_initialize_t = sym("sourcekitd_initialize") else { handle = nil; return false }
        fromYAML = sym("sourcekitd_request_create_from_yaml")
        send = sym("sourcekitd_send_request_sync")
        releaseRequest = sym("sourcekitd_request_release")
        disposeResponse = sym("sourcekitd_response_dispose")
        isError = sym("sourcekitd_response_is_error")
        responseValue = sym("sourcekitd_response_get_value")
        uidFromCStr = sym("sourcekitd_uid_get_from_cstr")
        uidString = sym("sourcekitd_uid_get_string_ptr")
        dictValue = sym("sourcekitd_variant_dictionary_get_value")
        dictUID = sym("sourcekitd_variant_dictionary_get_uid")
        dictInt = sym("sourcekitd_variant_dictionary_get_int64")
        arrayCount = sym("sourcekitd_variant_array_get_count")
        arrayValue = sym("sourcekitd_variant_array_get_value")
        dictString = sym("sourcekitd_variant_dictionary_get_string")
        variantType = sym("sourcekitd_variant_get_type")

        guard fromYAML != nil, send != nil, responseValue != nil, dictValue != nil else {
            handle = nil
            return false
        }
        initialize()
        log.notice("sourcekitd loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return true
    }

    private func uid(_ name: String) -> sourcekitd_uid_t? {
        if let cached = uids[name] { return cached }
        guard let made = name.withCString({ uidFromCStr?($0) }) else { return nil }
        uids[name] = made
        return made
    }

    private func string(ofUID variant: sourcekitd_variant_t, key: String) -> String? {
        guard let key = uid(key), let u = dictUID?(variant, key), let s = uidString?(u) else {
            return nil
        }
        return String(cString: s)
    }

    private func int(_ variant: sourcekitd_variant_t, _ key: String) -> Int? {
        guard let key = uid(key) else { return nil }
        // The API returns 0 for a missing key, which is indistinguishable from a real 0
        // offset — so check the value exists before trusting it.
        guard let value = dictValue?(variant, key),
              variantType?(value) != SOURCEKITD_VARIANT_TYPE_NULL else { return nil }
        return Int(dictInt?(variant, key) ?? 0)
    }

    /// Which files sourcekitd is allowed to see.
    ///
    /// **The gate matters more than it looks.** sourcekitd parses whatever it is handed as
    /// Swift and answers confidently: a Markdown file comes back with a stray `class` in it
    /// because some sentence happened to parse. There is no error to catch — the defence is
    /// not asking. Everything else previews as plain text, which is the right answer for a
    /// README rather than a gap.
    static let parsableExtensions: Set<String> = ["swift"]

    static func canParse(_ path: String) -> Bool {
        parsableExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Parse one file. Returns nil when sourcekitd is unavailable or the file is not Swift.
    ///
    /// Synchronous and **not** for the main thread: call it from the loader's background queue.
    func parse(path: String, lines: LineTable,
               bytes: [UInt8]) -> (tokens: [SyntaxToken], outline: [OutlineNode])? {
        guard Self.canParse(path), load() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let fromYAML, let send, let responseValue else { return nil }

        // A name unique per call: sourcekitd keeps documents open by name, and reusing one
        // would make every request after the first an edit of the last file.
        let name = "xcommander.preview.\(UUID().uuidString)"
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "\"", with: "\\\"")
        let yaml = """
        {
          key.request: source.request.editor.open,
          key.name: "\(name)",
          key.sourcefile: "\(escaped)",
          key.syntactic_only: 1
        }
        """
        var error: UnsafeMutablePointer<CChar>?
        guard let request = yaml.withCString({ fromYAML($0, &error) }) else { return nil }
        defer { releaseRequest?(request) }
        guard let response = send(request) else { return nil }
        defer {
            disposeResponse?(response)
            closeDocument(named: name)
        }
        if isError?(response) ?? false { return nil }

        let root = responseValue(response)
        return (tokens(in: root, lines: lines), outline(in: root, lines: lines, bytes: bytes))
    }

    /// sourcekitd keeps every opened document in memory until it is closed.
    private func closeDocument(named name: String) {
        guard let fromYAML, let send else { return }
        let yaml = "{ key.request: source.request.editor.close, key.name: \"\(name)\" }"
        guard let request = yaml.withCString({ fromYAML($0, nil) }) else { return }
        if let response = send(request) { disposeResponse?(response) }
        releaseRequest?(request)
    }

    // MARK: - syntax

    private func tokens(in root: sourcekitd_variant_t, lines: LineTable) -> [SyntaxToken] {
        guard let key = uid("key.syntaxmap"), let map = dictValue?(root, key),
              let count = arrayCount?(map), count > 0 else { return [] }
        var result: [SyntaxToken] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let entry = arrayValue?(map, i),
                  let kind = string(ofUID: entry, key: "key.kind"),
                  let offset = int(entry, "key.offset"),
                  let length = int(entry, "key.length"), length > 0 else { continue }
            let role = Self.role(for: kind)
            guard role != .plain else { continue }
            result.append(SyntaxToken(role: role, offset: offset, length: length))
        }
        return result
    }

    /// sourcekitd's syntax vocabulary, reduced to what a pane paints. Anything unlisted is
    /// plain text and is dropped rather than coloured badly.
    private static func role(for kind: String) -> SyntaxRole {
        switch kind {
        case "source.lang.swift.syntaxtype.keyword": .keyword
        case "source.lang.swift.syntaxtype.string", "source.lang.swift.syntaxtype.string_interpolation_anchor": .string
        case "source.lang.swift.syntaxtype.number": .number
        case "source.lang.swift.syntaxtype.comment", "source.lang.swift.syntaxtype.comment.mark",
             "source.lang.swift.syntaxtype.comment.url": .comment
        case "source.lang.swift.syntaxtype.doccomment", "source.lang.swift.syntaxtype.doccomment.field": .docComment
        case "source.lang.swift.syntaxtype.typeidentifier": .typeName
        case "source.lang.swift.syntaxtype.attribute.builtin", "source.lang.swift.syntaxtype.attribute.id": .attribute
        default: .plain
        }
    }

    // MARK: - outline

    private func outline(in node: sourcekitd_variant_t, lines: LineTable,
                         bytes: [UInt8]) -> [OutlineNode] {
        guard let key = uid("key.substructure"), let children = dictValue?(node, key),
              let count = arrayCount?(children), count > 0 else { return [] }
        var result: [OutlineNode] = []
        for i in 0..<count {
            guard let entry = arrayValue?(children, i) else { continue }
            let nested = outline(in: entry, lines: lines, bytes: bytes)
            guard let kindName = string(ofUID: entry, key: "key.kind"),
                  let kind = Self.symbolKind(for: kindName) else {
                // Not a declaration — a `stmt.if`, an `expr.call`. Its children might still
                // be: an extension's methods sit under structural nodes. Lift them.
                result.append(contentsOf: nested)
                continue
            }
            guard let name = stringValue(entry, "key.name"), !name.isEmpty else {
                result.append(contentsOf: nested)
                continue
            }
            let offset = int(entry, "key.nameoffset") ?? int(entry, "key.offset") ?? 0
            let access = string(ofUID: entry, key: "key.accessibility")
            result.append(OutlineNode(
                name: name,
                kind: kind,
                line: lines.line(atByteOffset: offset),
                isPublic: access == "source.lang.swift.accessibility.public"
                    || access == "source.lang.swift.accessibility.open",
                summary: documentation(entry, in: bytes),
                children: nested))
        }
        return result
    }

    /// The declaration's own documentation, reduced to one line.
    ///
    /// `key.docoffset` and `key.doclength` are a byte range into the file covering the raw
    /// comment, markers included, so the slice is taken in bytes and reduced in Core.
    private func documentation(_ entry: sourcekitd_variant_t, in bytes: [UInt8]) -> String? {
        guard let offset = int(entry, "key.docoffset"),
              let length = int(entry, "key.doclength"),
              length > 0, offset >= 0, offset + length <= bytes.count else { return nil }
        let raw = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
        return DocSummary.firstSentence(of: raw)
    }

    private func stringValue(_ variant: sourcekitd_variant_t, _ key: String) -> String? {
        guard let key = uid(key), let s = dictString?(variant, key) else { return nil }
        return String(cString: s)
    }

    /// sourcekitd's declaration kinds mapped onto the vocabulary the picker already speaks,
    /// so an outline row wears the same badge the symbol picker gives the same thing.
    /// Anything that is not a declaration returns nil and is skipped.
    private static func symbolKind(for kind: String) -> SymbolKind? {
        switch kind {
        case "source.lang.swift.decl.struct": .struct
        case "source.lang.swift.decl.class", "source.lang.swift.decl.actor": .class
        case "source.lang.swift.decl.enum": .enum
        case "source.lang.swift.decl.enumelement": .enumConstant
        case "source.lang.swift.decl.protocol": .protocol
        case "source.lang.swift.decl.typealias", "source.lang.swift.decl.associatedtype": .typeAlias
        case "source.lang.swift.decl.macro": .macro
        case "source.lang.swift.decl.function.free": .function
        case "source.lang.swift.decl.function.method.instance": .instanceMethod
        case "source.lang.swift.decl.function.method.static": .staticMethod
        case "source.lang.swift.decl.function.method.class": .classMethod
        case "source.lang.swift.decl.function.constructor": .constructor
        case "source.lang.swift.decl.function.destructor": .destructor
        case "source.lang.swift.decl.var.instance": .instanceProperty
        case "source.lang.swift.decl.var.static": .staticProperty
        case "source.lang.swift.decl.var.class": .classProperty
        case "source.lang.swift.decl.var.global": .variable
        case let k where k.hasPrefix("source.lang.swift.decl.extension"): .extension
        default: nil
        }
    }
}
