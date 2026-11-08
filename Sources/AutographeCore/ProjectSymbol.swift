import Foundation

/// A declaration Xcode's index knows about.
public struct ProjectSymbol: Hashable, Sendable {
    public let name: String
    public let kind: SymbolKind
    public let path: String
    public let line: Int

    public init(name: String, kind: SymbolKind, path: String, line: Int) {
        self.name = name
        self.kind = kind
        self.path = path
        self.line = line
    }

    public func location(relativeTo root: String?) -> String {
        let file = (path as NSString).lastPathComponent
        guard let root else { return "\(file):\(line)" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let shown = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file
        return "\(shown):\(line)"
    }
}

/// The symbol kinds the index reports, in the order clang's `indexstore.h` numbers them.
public enum SymbolKind: UInt32, Hashable, Sendable, CaseIterable {
    case unknown = 0, module, namespace, namespaceAlias, macro, `enum`, `struct`, `class`
    case `protocol`, `extension`, union, typeAlias, function, variable, field
    case enumConstant, instanceMethod, classMethod, staticMethod, instanceProperty
    case classProperty, staticProperty, constructor, destructor, conversionFunction
    case parameter, using, concept, commentTag

    public init(raw: UInt32) { self = SymbolKind(rawValue: raw) ?? .unknown }

    /// The short label the picker shows.
    public var label: String {
        switch self {
        case .enum: "enum"
        case .struct: "struct"
        case .class: "class"
        case .protocol: "protocol"
        case .extension: "extension"
        case .typeAlias: "typealias"
        case .function: "func"
        case .instanceMethod, .classMethod, .staticMethod: "method"
        case .constructor: "init"
        case .variable: "var"
        case .macro: "macro"
        case .instanceProperty, .classProperty, .staticProperty: "property"
        case .field: "field"
        case .enumConstant: "case"
        default: "\(self)"
        }
    }

    /// The kinds worth putting in a "jump to symbol" list.
    ///
    /// This matters more than fetching does. The raw store holds 76,765 symbols for a small
    /// package; 929 are in project files and **96 are these**. The index records a getter,
    /// a setter and a parameter for every property, so a picker that shows everything is
    /// unusable.
    public var isNavigable: Bool {
        switch self {
        case .enum, .struct, .class, .protocol, .extension, .typeAlias,
             .function, .instanceMethod, .classMethod, .staticMethod,
             .constructor, .variable, .macro:
            true
        default:
            false
        }
    }
}

/// What to keep out of a symbol list, as a pure decision so it can be tested.
public enum SymbolFilter {

    /// Accessors are recorded as their own methods (`getter:name`), and there is one for
    /// every property in the project.
    public static func isAccessor(_ name: String) -> Bool {
        name.hasPrefix("getter:") || name.hasPrefix("setter:")
    }

    /// The index covers the SDK and Xcode's own headers as well as the project. Nobody
    /// opens a symbol picker in their app to find `UIView`.
    public static func isOutsideProject(_ path: String) -> Bool {
        path.contains("/Xcode.app/") || path.contains("/SDKs/")
            || path.contains("/DerivedData/") || path.contains("/.build/")
            || path.hasPrefix("/usr/") || path.hasPrefix("/Library/")
    }

    public static func keep(_ symbol: ProjectSymbol) -> Bool {
        symbol.kind.isNavigable
            && !symbol.name.isEmpty
            && !isAccessor(symbol.name)
            && !isOutsideProject(symbol.path)
    }

    /// Filter, de-duplicate and order a raw symbol list.
    ///
    /// The same declaration appears once per unit that compiled the file, so a type in a
    /// package built for several destinations shows up several times.
    public static func prepare(_ symbols: [ProjectSymbol]) -> [ProjectSymbol] {
        var seen = Set<ProjectSymbol>()
        var out: [ProjectSymbol] = []
        out.reserveCapacity(symbols.count)
        for symbol in symbols where keep(symbol) {
            if seen.insert(symbol).inserted { out.append(symbol) }
        }
        out.sort {
            $0.name == $1.name
                ? ($0.path == $1.path ? $0.line < $1.line : $0.path < $1.path)
                : $0.name.lowercased() < $1.name.lowercased()
        }
        return out
    }
}
