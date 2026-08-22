import SwiftUI

struct ToolbarSettingsView: View {

    @ObservedObject private var store = QuickActionStore.shared

    var body: some View {
        List {
            itemsSection
            addSection
        }
        .navigationTitle("Toolbar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
        }
    }

    private var itemsSection: some View {
        Section {
            if store.items.isEmpty {
                Text("No buttons yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.items) { item in
                HStack(spacing: 12) {
                    Image(systemName: item.listSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text(item.title)
                        .lineLimit(1)
                }
            }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { store.remove(atOffsets: $0) }
        } header: {
            Text("Toolbar buttons")
        }
    }

    private var addSection: some View {
        Section {
            NavigationLink {
                AddToolbarItemView()
            } label: {
                Text("Add a button")
            }
            Button {
                store.append(.separator)
            } label: {
                Text("Add a separator")
            }
            Button(role: .destructive) {
                store.resetToDefaults()
            } label: {
                Text("Reset to defaults")
            }
        } header: {
            Text("Manage")
        }
    }
}

struct AddToolbarItemView: View {

    @ObservedObject private var store = QuickActionStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CustomShortcutView()
                } label: {
                    Text("Custom shortcut")
                }
            } header: {
                Text("Your own")
            }

            Section {
                ForEach(ToolbarCombo.allCases) { combo in
                    addRow(symbol: combo.symbol, title: combo.title, detail: combo.detail) {
                        store.append(.combo(combo))
                    }
                }
            } header: {
                Text("Combos")
            }

            Section {
                ForEach(ToolbarBuiltin.allCases) { action in
                    addRow(symbol: action.listSymbol, title: action.title, detail: action.detail) {
                        store.append(.builtin(action))
                    }
                }
            } header: {
                Text("Modifiers and keys")
            }

            Section {
                addRow(symbol: "line.3.horizontal", title: "Separator",
                       detail: ToolbarActionItem.separator.detail) {
                    store.append(.separator)
                }
            } header: {
                Text("Spacing")
            }
        }
        .navigationTitle("Add a button")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addRow(symbol: String, title: String, detail: String,
                        add: @escaping () -> Void) -> some View {
        Button {
            add()
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title)")
        .accessibilityHint(detail)
    }
}

struct CustomShortcutView: View {

    @ObservedObject private var store = QuickActionStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var command = true
    @State private var option = false
    @State private var control = false
    @State private var shift = false
    @State private var key = ""
    @State private var label = ""
    @State private var symbol = "command"

    private static let columns = [GridItem(.adaptive(minimum: 46), spacing: 8)]

    private var modifiers: WireModifiers {
        var result: WireModifiers = []
        if command { result.insert(.command) }
        if option { result.insert(.option) }
        if control { result.insert(.control) }
        if shift { result.insert(.shift) }
        return result
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Command ⌘", isOn: $command)
                Toggle("Option ⌥", isOn: $option)
                Toggle("Control ⌃", isOn: $control)
                Toggle("Shift ⇧", isOn: $shift)
            } header: {
                Text("Modifiers")
            }

            Section {
                Picker("Key", selection: $key) {
                    Text("None").tag("")
                    ForEach(WireKeyCatalog.groups) { group in
                        Section(group.title) {
                            ForEach(group.keys) { entry in
                                Text(entry.label).tag(entry.name)
                            }
                        }
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Key")
            } footer: {
                Text(trimmedKey.isEmpty
                     ? "Pick a key: a shortcut without one cannot be added."
                     : "Sends \(ToolbarShortcutText.description(mods: modifiers, key: trimmedKey)) with any latched modifiers on top.")
            }

            Section {
                TextField("Short label", text: $label)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Label")
            }

            Section {
                symbolGrid
            } header: {
                Text("Icon")
            }

            Section {
                Button(action: save) {
                    Text("Add to toolbar")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .disabled(trimmedKey.isEmpty)
            }
        }
        .navigationTitle("Custom shortcut")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Self.columns, spacing: 8) {
            ForEach(ToolbarSymbolCatalog.symbols, id: \.self) { name in
                symbolCell(name)
            }
        }
        .padding(.vertical, 6)
    }

    private func symbolCell(_ name: String) -> some View {
        let active = symbol == name
        return Button {
            symbol = name
        } label: {
            Image(systemName: name)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 42, height: 38)
                .foregroundStyle(Color.primary)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? AnyShapeStyle(Color(.systemFill))
                                 : AnyShapeStyle(Color(.tertiarySystemFill))))
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func save() {
        guard !trimmedKey.isEmpty else { return }
        store.append(.custom(mods: modifiers, key: trimmedKey,
                             label: label.trimmingCharacters(in: .whitespaces),
                             symbol: symbol))
        dismiss()
    }
}
