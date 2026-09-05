import Testing
@testable import CompanionCore

/// Reading Xcode's index is the easy half. **Filtering it is the half that decides whether
/// the picker is usable**: the raw store held 76,765 symbols for a small package, 929 in
/// project files, and 96 worth navigating to.
@Suite("Project symbols")
struct SymbolTests {

    private func symbol(_ name: String, _ kind: SymbolKind,
                        _ path: String = "/p/Sources/A.swift", _ line: Int = 1) -> ProjectSymbol {
        ProjectSymbol(name: name, kind: kind, path: path, line: line)
    }

    @Test("the kinds a person navigates to are kept")
    func navigableKinds() {
        for kind in [SymbolKind.struct, .class, .enum, .protocol, .extension, .typeAlias,
                     .function, .instanceMethod, .classMethod, .staticMethod, .constructor,
                     .variable, .macro] {
            #expect(kind.isNavigable, "\(kind) should be navigable")
        }
    }

    /// The index records one of each of these for every property in the project. Showing
    /// them would bury every real declaration.
    @Test("accessors, parameters and fields are not navigable")
    func noiseKinds() {
        for kind in [SymbolKind.parameter, .instanceProperty, .classProperty,
                     .staticProperty, .field, .enumConstant, .unknown, .module] {
            #expect(!kind.isNavigable, "\(kind) should not be navigable")
        }
    }

    @Test("getter and setter entries are dropped by name as well as by kind")
    func accessorNames() {
        #expect(SymbolFilter.isAccessor("getter:title"))
        #expect(SymbolFilter.isAccessor("setter:title"))
        #expect(!SymbolFilter.isAccessor("title"))
        #expect(!SymbolFilter.keep(symbol("getter:title", .instanceMethod)))
    }

    /// The index covers the SDK and Xcode's own headers. Nobody opens a symbol picker in
    /// their app to find `UIView`.
    @Test("symbols outside the project are dropped", arguments: [
        "/Applications/Xcode.app/Contents/Developer/SDKs/x.h",
        "/Users/w/Library/Developer/Xcode/DerivedData/P-abc/Build/x.swift",
        "/usr/include/stdio.h",
        "/Library/Frameworks/A.framework/A.h",
        "/p/.build/checkouts/dep/S.swift",
    ])
    func outsideProject(path: String) {
        #expect(SymbolFilter.isOutsideProject(path))
        #expect(!SymbolFilter.keep(symbol("Thing", .struct, path)))
    }

    @Test("a project symbol is kept")
    func keepsProjectSymbol() {
        #expect(SymbolFilter.keep(symbol("PickerSession", .struct)))
    }

    /// The same declaration is recorded once per unit that compiled the file, so a package
    /// built for several destinations reports each type several times.
    @Test("duplicates from several build units collapse to one row")
    func deduplicates() {
        let one = symbol("PickerSession", .struct, "/p/Picker.swift", 52)
        let prepared = SymbolFilter.prepare([one, one, one])
        #expect(prepared.count == 1)
    }

    @Test("the same name at a different line is not a duplicate")
    func distinctLines() {
        let a = symbol("run", .instanceMethod, "/p/A.swift", 10)
        let b = symbol("run", .instanceMethod, "/p/A.swift", 20)
        #expect(SymbolFilter.prepare([a, b]).count == 2)
    }

    @Test("preparing filters, dedupes and sorts by name")
    func prepareEndToEnd() {
        let input = [
            symbol("zebra", .struct),
            symbol("getter:x", .instanceMethod),
            symbol("Alpha", .class),
            symbol("param", .parameter),
            symbol("UIView", .class, "/Applications/Xcode.app/SDKs/UIKit.h"),
            symbol("middle", .function),
        ]
        let prepared = SymbolFilter.prepare(input)
        #expect(prepared.map(\.name) == ["Alpha", "middle", "zebra"])
    }

    @Test("an unknown raw kind degrades to .unknown rather than trapping")
    func unknownKind() {
        #expect(SymbolKind(raw: 9999) == .unknown)
        #expect(SymbolKind(raw: 6) == .struct)
    }

    @Test("labels are short enough for a picker row")
    func labels() {
        #expect(SymbolKind.struct.label == "struct")
        #expect(SymbolKind.instanceMethod.label == "method")
        #expect(SymbolKind.constructor.label == "init")
        #expect(SymbolKind.typeAlias.label == "typealias")
    }

    @Test("locations are shown relative to the project root")
    func locations() {
        let s = symbol("A", .struct, "/p/Sources/A.swift", 12)
        #expect(s.location(relativeTo: "/p") == "Sources/A.swift:12")
        #expect(s.location(relativeTo: nil) == "A.swift:12")
        // A symbol outside the root falls back to the file name rather than a wrong path.
        #expect(s.location(relativeTo: "/other") == "A.swift:12")
    }
}
