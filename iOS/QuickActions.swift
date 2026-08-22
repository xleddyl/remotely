import Foundation

enum ToolbarBuiltin: String, Codable, CaseIterable, Identifiable {
    case pointerMode
    case command, option, control, shift
    case escape, tab, returnKey, forwardDelete
    case home, end, pageUp, pageDown
    case arrowLeft, arrowDown, arrowUp, arrowRight

    var id: String { rawValue }

    var modifier: WireModifiers? {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        default: return nil
        }
    }

    var key: String? {
        switch self {
        case .escape: return "escape"
        case .tab: return "tab"
        case .returnKey: return "return"
        case .forwardDelete: return "forwardDelete"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageUp"
        case .pageDown: return "pageDown"
        case .arrowLeft: return "left"
        case .arrowDown: return "down"
        case .arrowUp: return "up"
        case .arrowRight: return "right"
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .pointerMode: return "Pointer mode"
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .returnKey: return "Return"
        case .forwardDelete: return "Forward delete"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page up"
        case .pageDown: return "Page down"
        case .arrowLeft: return "Arrow left"
        case .arrowDown: return "Arrow down"
        case .arrowUp: return "Arrow up"
        case .arrowRight: return "Arrow right"
        }
    }

    var detail: String {
        switch self {
        case .pointerMode: return "Pointer mode: switches touch between tapping directly on the picture and using this device as a trackpad."
        case .command: return "Command: latches ⌘ until you tap it again, so the next tap or keystroke carries it."
        case .option: return "Option: latches ⌥ until you tap it again, so the next tap or keystroke carries it."
        case .control: return "Control: latches ⌃ until you tap it again, so the next tap or keystroke carries it."
        case .shift: return "Shift: latches ⇧ until you tap it again, so the next tap or keystroke carries it."
        case .escape: return "Escape: sends the esc key."
        case .tab: return "Tab: sends the tab key."
        case .returnKey: return "Return: sends the return key."
        case .forwardDelete: return "Forward delete: deletes the character after the caret."
        case .home: return "Home: jumps to the start of the line or document."
        case .end: return "End: jumps to the end of the line or document."
        case .pageUp: return "Page up: scrolls one screen up."
        case .pageDown: return "Page down: scrolls one screen down."
        case .arrowLeft: return "Arrow left: sends the left arrow key."
        case .arrowDown: return "Arrow down: sends the down arrow key."
        case .arrowUp: return "Arrow up: sends the up arrow key."
        case .arrowRight: return "Arrow right: sends the right arrow key."
        }
    }

    var symbol: String? {
        switch self {
        case .pointerMode: return "cursorarrow"
        case .returnKey: return "return"
        case .forwardDelete: return "delete.right"
        case .home: return "arrow.up.to.line"
        case .end: return "arrow.down.to.line"
        case .arrowLeft: return "arrow.left"
        case .arrowDown: return "arrow.down"
        case .arrowUp: return "arrow.up"
        case .arrowRight: return "arrow.right"
        default: return nil
        }
    }

    var glyph: String? {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .escape: return "esc"
        case .tab: return "tab"
        case .pageUp: return "pgup"
        case .pageDown: return "pgdn"
        default: return nil
        }
    }

    var listSymbol: String {
        switch self {
        case .pointerMode: return "cursorarrow"
        case .command: return "command"
        case .option: return "option"
        case .control: return "control"
        case .shift: return "shift"
        case .escape: return "escape"
        case .tab: return "arrow.right.to.line"
        case .returnKey: return "return"
        case .forwardDelete: return "delete.right"
        case .home: return "arrow.up.to.line"
        case .end: return "arrow.down.to.line"
        case .pageUp: return "chevron.up.square"
        case .pageDown: return "chevron.down.square"
        case .arrowLeft: return "arrow.left"
        case .arrowDown: return "arrow.down"
        case .arrowUp: return "arrow.up"
        case .arrowRight: return "arrow.right"
        }
    }
}

enum ToolbarCombo: String, Codable, CaseIterable, Identifiable {
    case desktopLeft, desktopRight, missionControl, appExpose, spotlight

    var id: String { rawValue }

    var modifiers: WireModifiers {
        switch self {
        case .desktopLeft, .desktopRight, .missionControl, .appExpose: return .control
        case .spotlight: return .command
        }
    }

    var key: String {
        switch self {
        case .desktopLeft: return "left"
        case .desktopRight: return "right"
        case .missionControl: return "up"
        case .appExpose: return "down"
        case .spotlight: return "space"
        }
    }

    var title: String {
        switch self {
        case .desktopLeft: return "Desktop left"
        case .desktopRight: return "Desktop right"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .spotlight: return "Spotlight"
        }
    }

    var detail: String {
        switch self {
        case .desktopLeft: return "Desktop left: switches to the Space on the left, the macOS Control-Left shortcut."
        case .desktopRight: return "Desktop right: switches to the Space on the right, the macOS Control-Right shortcut."
        case .missionControl: return "Mission Control: shows every window and Space, the macOS Control-Up shortcut."
        case .appExpose: return "App Exposé: shows every window of the front app, the macOS Control-Down shortcut."
        case .spotlight: return "Spotlight: opens Spotlight search, the macOS Command-Space shortcut."
        }
    }

    var symbol: String {
        switch self {
        case .desktopLeft: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .desktopRight: return "rectangle.righthalf.inset.filled.arrow.right"
        case .missionControl: return "macwindow.on.rectangle"
        case .appExpose: return "rectangle.stack"
        case .spotlight: return "magnifyingglass"
        }
    }
}

struct ToolbarActionItem: Codable, Identifiable, Equatable {

    enum Kind: String, Codable { case builtin, combo, custom, separator }

    var id: UUID
    var kind: Kind
    var builtin: ToolbarBuiltin?
    var combo: ToolbarCombo?
    var mods: Int?
    var key: String?
    var label: String?
    var symbol: String?

    init(id: UUID = UUID(), kind: Kind, builtin: ToolbarBuiltin? = nil,
         combo: ToolbarCombo? = nil, mods: Int? = nil, key: String? = nil,
         label: String? = nil, symbol: String? = nil) {
        self.id = id
        self.kind = kind
        self.builtin = builtin
        self.combo = combo
        self.mods = mods
        self.key = key
        self.label = label
        self.symbol = symbol
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .separator
        builtin = (try? container.decodeIfPresent(ToolbarBuiltin.self, forKey: .builtin)) ?? nil
        combo = (try? container.decodeIfPresent(ToolbarCombo.self, forKey: .combo)) ?? nil
        mods = (try? container.decodeIfPresent(Int.self, forKey: .mods)) ?? nil
        key = (try? container.decodeIfPresent(String.self, forKey: .key)) ?? nil
        label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? nil
        symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? nil
    }

    static func builtin(_ action: ToolbarBuiltin) -> ToolbarActionItem {
        ToolbarActionItem(kind: .builtin, builtin: action)
    }

    static func combo(_ preset: ToolbarCombo) -> ToolbarActionItem {
        ToolbarActionItem(kind: .combo, combo: preset)
    }

    static func custom(mods: WireModifiers, key: String, label: String, symbol: String) -> ToolbarActionItem {
        ToolbarActionItem(kind: .custom, mods: mods.rawValue, key: key,
                          label: label, symbol: symbol)
    }

    static var separator: ToolbarActionItem {
        ToolbarActionItem(kind: .separator)
    }

    var isValid: Bool {
        switch kind {
        case .builtin: return builtin != nil
        case .combo: return combo != nil
        case .custom: return !(key ?? "").isEmpty
        case .separator: return true
        }
    }

    var wireModifiers: WireModifiers {
        switch kind {
        case .combo: return combo?.modifiers ?? []
        case .custom: return WireModifiers(rawValue: mods ?? 0)
        default: return []
        }
    }

    var wireKey: String? {
        switch kind {
        case .builtin: return builtin?.key
        case .combo: return combo?.key
        case .custom: return key
        default: return nil
        }
    }

    var title: String {
        switch kind {
        case .builtin: return builtin?.title ?? "Action"
        case .combo: return combo?.title ?? "Combo"
        case .custom:
            let name = (label ?? "").trimmingCharacters(in: .whitespaces)
            guard name.isEmpty else { return name }
            return ToolbarShortcutText.description(mods: wireModifiers, key: key ?? "")
        case .separator: return "Separator"
        }
    }

    var detail: String {
        switch kind {
        case .builtin: return builtin?.detail ?? ""
        case .combo: return combo?.detail ?? ""
        case .custom:
            return "Custom shortcut: sends \(ToolbarShortcutText.description(mods: wireModifiers, key: key ?? ""))."
        case .separator: return "Separator: a thin divider that groups the buttons around it."
        }
    }

    var listSymbol: String {
        switch kind {
        case .builtin: return builtin?.listSymbol ?? "square"
        case .combo: return combo?.symbol ?? "square"
        case .custom:
            let name = (symbol ?? "").trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "command" : name
        case .separator: return "line.3.horizontal"
        }
    }
}

enum ToolbarShortcutText {

    static func description(mods: WireModifiers, key: String) -> String {
        glyphs(for: mods) + WireKeyCatalog.label(for: key)
    }

    static func glyphs(for mods: WireModifiers) -> String {
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        return text
    }
}

enum WireKeyCatalog {

    struct Key: Identifiable, Hashable {
        let name: String
        let label: String
        var id: String { name }
    }

    struct Group: Identifiable {
        let title: String
        let keys: [Key]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Letters", keys: "abcdefghijklmnopqrstuvwxyz".map {
            Key(name: String($0), label: String($0).uppercased())
        }),
        Group(title: "Numbers", keys: "0123456789".map {
            Key(name: String($0), label: String($0))
        }),
        Group(title: "Punctuation", keys: [
            Key(name: "space", label: "Space"),
            Key(name: "-", label: "Minus (-)"),
            Key(name: "=", label: "Equals (=)"),
            Key(name: "[", label: "Left bracket ([)"),
            Key(name: "]", label: "Right bracket (])"),
            Key(name: "\\", label: "Backslash (\\)"),
            Key(name: ";", label: "Semicolon (;)"),
            Key(name: "'", label: "Quote (')"),
            Key(name: "`", label: "Backtick (`)"),
            Key(name: ",", label: "Comma (,)"),
            Key(name: ".", label: "Period (.)"),
            Key(name: "/", label: "Slash (/)"),
        ]),
        Group(title: "Editing", keys: [
            Key(name: "escape", label: "Escape"),
            Key(name: "tab", label: "Tab"),
            Key(name: "return", label: "Return"),
            Key(name: "enter", label: "Enter (keypad)"),
            Key(name: "delete", label: "Delete"),
            Key(name: "forwardDelete", label: "Forward delete"),
        ]),
        Group(title: "Navigation", keys: [
            Key(name: "left", label: "Arrow left"),
            Key(name: "down", label: "Arrow down"),
            Key(name: "up", label: "Arrow up"),
            Key(name: "right", label: "Arrow right"),
            Key(name: "home", label: "Home"),
            Key(name: "end", label: "End"),
            Key(name: "pageUp", label: "Page up"),
            Key(name: "pageDown", label: "Page down"),
        ]),
        Group(title: "Function keys", keys: (1...20).map {
            Key(name: "f\($0)", label: "F\($0)")
        }),
    ]

    static let all: [Key] = groups.flatMap { $0.keys }

    private static let labels: [String: String] = {
        var map: [String: String] = [:]
        for key in all { map[key.name] = key.label }
        return map
    }()

    static func label(for name: String) -> String {
        labels[name] ?? name
    }
}

enum ToolbarSymbolCatalog {
    static let symbols: [String] = [
        "command", "option", "control", "shift", "escape", "return",
        "delete.left", "delete.right", "arrow.left", "arrow.down",
        "arrow.up", "arrow.right", "arrow.uturn.backward", "arrow.uturn.forward",
        "magnifyingglass", "macwindow", "macwindow.on.rectangle", "rectangle.stack",
        "square.grid.2x2", "sidebar.left", "sidebar.right", "doc.on.doc",
        "doc.on.clipboard", "scissors", "trash", "folder",
        "square.and.arrow.up", "tray.and.arrow.down", "plus", "minus",
        "xmark", "checkmark", "star", "bolt", "flame", "bell",
        "lock", "eye", "terminal", "hammer", "wrench", "gear",
        "paintbrush", "wand.and.stars", "sparkles", "play.fill",
        "pause.fill", "speaker.wave.2.fill", "speaker.slash.fill",
        "sun.max", "moon", "globe", "link", "text.cursor",
        "textformat", "bold", "italic", "list.bullet", "clock",
        "calendar", "camera", "photo", "keyboard", "cursorarrow",
    ]
}

final class QuickActionStore: ObservableObject {

    static let shared = QuickActionStore()
    static let defaultsKey = "toolbarQuickActions"

    static let defaultItems: [ToolbarActionItem] = [
        .builtin(.pointerMode),
        .separator,
        .builtin(.command),
        .builtin(.option),
        .builtin(.control),
        .builtin(.shift),
        .separator,
        .builtin(.escape),
        .builtin(.tab),
        .separator,
        .builtin(.arrowLeft),
        .builtin(.arrowDown),
        .builtin(.arrowUp),
        .builtin(.arrowRight),
    ]

    @Published var items: [ToolbarActionItem] { didSet { save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.stored(in: defaults) ?? Self.defaultItems
    }

    func append(_ item: ToolbarActionItem) {
        items.append(item)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func resetToDefaults() {
        items = Self.defaultItems
    }

    private static func stored(in defaults: UserDefaults) -> [ToolbarActionItem]? {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ToolbarActionItem].self, from: data)
        else { return nil }
        return decoded.filter { $0.isValid }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
