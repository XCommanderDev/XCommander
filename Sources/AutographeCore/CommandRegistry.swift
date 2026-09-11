import Foundation

/// Every command in the product, in one table.
///
/// This is the piece that keeps the which-key panel and the command palette honest with
/// each other. The panel is this registry filtered by key prefix; the palette is this
/// registry fuzzy-matched by text. **Adding a command adds it to both**, because there is
/// nowhere else to add it.
///
/// The keymap binds *identifiers*, not commands: register first, then bind by id. Binding
/// commands directly is how you end up with two copies of the same command that drift.
public struct CommandRegistry: Sendable {
    private var byID: [String: Command] = [:]
    private var order: [String] = []

    public init() {}

    public mutating func register(_ command: Command) {
        if byID[command.id] == nil { order.append(command.id) }
        byID[command.id] = command
    }

    public mutating func register(contentsOf commands: [Command]) {
        for command in commands { register(command) }
    }

    public func command(id: String) -> Command? { byID[id] }

    /// Registration order, which is the order the palette shows before anything is typed.
    public var all: [Command] { order.compactMap { byID[$0] } }

    public var count: Int { byID.count }

    /// The palette's rows. `searchText` is what the matcher sees, so a menu-backed command
    /// is findable by its full path (`Product > Build`) rather than only its short title.
    public func pickerItems(binding: (String) -> String?) -> [PickerItem] {
        all.map { command in
            PickerItem(id: command.id,
                       title: command.searchText,
                       detail: binding(command.id),
                       isEnabled: true)
        }
    }
}
