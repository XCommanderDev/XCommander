import Foundation
import CIndexStore
import os

/// `libIndexStore.dylib`, loaded from whichever Xcode the user has selected.
///
/// Every entry point is resolved with `dlsym` at launch and stored as an optional. Nothing
/// here is linked, so a missing, moved or older Xcode costs the symbol picker and nothing
/// else: `isAvailable` goes false, the picker says so, and the rest of the app never knows.
final class IndexStoreLibrary: @unchecked Sendable {

    static let shared = IndexStoreLibrary()

    private let handle: UnsafeMutableRawPointer?
    private let log = Logger(subsystem: "com.wassimans.AutographeForXcode", category: "index")

    let storeCreate: fn_store_create?
    let storeDispose: fn_store_dispose?
    let errorDescription: fn_error_get_description?
    let unitsApply: fn_store_units_apply?
    let unitReaderCreate: fn_unit_reader_create?
    let unitReaderDispose: fn_unit_reader_dispose?
    let unitDepsApply: fn_unit_deps_apply?
    let dependencyKind: fn_dependency_get_kind?
    let dependencyName: fn_dependency_get_name?
    let dependencyFilePath: fn_dependency_get_filepath?
    let recordReaderCreate: fn_record_reader_create?
    let recordReaderDispose: fn_record_reader_dispose?
    let recordOccurrencesApply: fn_record_occurrences_apply?
    let occurrenceSymbol: fn_occurrence_get_symbol?
    let occurrenceRoles: fn_occurrence_get_roles?
    let occurrenceLineCol: fn_occurrence_get_line_col?
    let symbolKind: fn_symbol_get_kind?
    let symbolName: fn_symbol_get_name?

    private init() {
        let handle = Self.open()
        self.handle = handle
        // A free function rather than a method: `self` is not fully initialised yet.
        func sym<T>(_ name: String) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T?.self)
        }
        storeCreate = sym("indexstore_store_create")
        storeDispose = sym("indexstore_store_dispose")
        errorDescription = sym("indexstore_error_get_description")
        unitsApply = sym("indexstore_store_units_apply_f")
        unitReaderCreate = sym("indexstore_unit_reader_create")
        unitReaderDispose = sym("indexstore_unit_reader_dispose")
        unitDepsApply = sym("indexstore_unit_reader_dependencies_apply_f")
        dependencyKind = sym("indexstore_unit_dependency_get_kind")
        dependencyName = sym("indexstore_unit_dependency_get_name")
        dependencyFilePath = sym("indexstore_unit_dependency_get_filepath")
        recordReaderCreate = sym("indexstore_record_reader_create")
        recordReaderDispose = sym("indexstore_record_reader_dispose")
        recordOccurrencesApply = sym("indexstore_record_reader_occurrences_apply_f")
        occurrenceSymbol = sym("indexstore_occurrence_get_symbol")
        occurrenceRoles = sym("indexstore_occurrence_get_roles")
        occurrenceLineCol = sym("indexstore_occurrence_get_line_col")
        symbolKind = sym("indexstore_symbol_get_kind")
        symbolName = sym("indexstore_symbol_get_name")

        if handle == nil {
            log.notice("libIndexStore not found; symbol pickers will be unavailable")
        } else if !isAvailable {
            log.notice("libIndexStore loaded but is missing entry points; symbols unavailable")
        }
    }

    /// True only when *every* entry point resolved. A partially-loaded library is treated
    /// as no library: half an API is how you get a crash instead of a message.
    var isAvailable: Bool {
        storeCreate != nil && storeDispose != nil && unitsApply != nil
            && unitReaderCreate != nil && unitReaderDispose != nil && unitDepsApply != nil
            && dependencyKind != nil && dependencyName != nil && dependencyFilePath != nil
            && recordReaderCreate != nil && recordReaderDispose != nil
            && recordOccurrencesApply != nil && occurrenceSymbol != nil
            && occurrenceRoles != nil && occurrenceLineCol != nil
            && symbolKind != nil && symbolName != nil
    }

    /// Ask `xcode-select` where the developer directory is rather than assuming
    /// `/Applications/Xcode.app`: people rename Xcode, keep several versions, or run betas.
    private static func open() -> UnsafeMutableRawPointer? {
        var roots: [String] = []
        if let selected = developerDirectory() { roots.append(selected) }
        roots.append("/Applications/Xcode.app/Contents/Developer")
        for root in roots {
            let path = root + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) { return handle }
        }
        return nil
    }

    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    static func string(_ ref: indexstore_string_ref_t) -> String {
        guard let data = ref.data, ref.length > 0, ref.length < 4096 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: data, count: ref.length), as: UTF8.self)
    }
}
