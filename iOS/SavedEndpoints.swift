import SwiftUI

struct SavedEndpoint: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: String

    init(id: UUID = UUID(), name: String = "", host: String, port: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }

    var displayName: String { name.isEmpty ? host : name }
    var displayAddress: String { "\(host):\(port)" }
}

final class SavedEndpointStore: ObservableObject {
    static let shared = SavedEndpointStore()

    @Published private(set) var endpoints: [SavedEndpoint] = []

    private let defaultsKey = "savedEndpoints"

    private init() {
        load()
        migrateLegacyManualEndpointIfNeeded()
    }

    func add(_ endpoint: SavedEndpoint) {
        endpoints.append(endpoint)
        persist()
    }

    func update(_ endpoint: SavedEndpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index] = endpoint
        persist()
    }

    func remove(_ endpoint: SavedEndpoint) {
        endpoints.removeAll { $0.id == endpoint.id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedEndpoint].self, from: data) else { return }
        endpoints = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(endpoints) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func migrateLegacyManualEndpointIfNeeded() {
        guard endpoints.isEmpty else { return }
        let defaults = UserDefaults.standard
        let legacyHost = defaults.string(forKey: "manualHost") ?? ""
        guard !legacyHost.isEmpty else { return }
        let legacyPort = defaults.string(forKey: "manualPort") ?? ManualEndpointParser.defaultPort
        endpoints = [SavedEndpoint(host: legacyHost, port: legacyPort)]
        persist()
        defaults.removeObject(forKey: "manualHost")
        defaults.removeObject(forKey: "manualPort")
    }
}

struct KnownMac: Codable, Identifiable, Equatable {
    let id: String
    var name: String
}

final class KnownMacStore: ObservableObject {
    static let shared = KnownMacStore()

    @Published private(set) var macs: [KnownMac] = []

    private let defaultsKey = "knownMacs"

    private init() {
        load()
    }

    func upsert(id: String, name: String) {
        if let index = macs.firstIndex(where: { $0.id == id }) {
            guard macs[index].name != name else { return }
            macs[index].name = name
        } else {
            macs.append(KnownMac(id: id, name: name))
        }
        persist()
    }

    func forget(_ mac: KnownMac) {
        macs.removeAll { $0.id == mac.id }
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([KnownMac].self, from: data) else { return }
        macs = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(macs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct SavedEndpointEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: SavedEndpoint?
    let onSave: (SavedEndpoint) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String

    init(existing: SavedEndpoint?, onSave: @escaping (SavedEndpoint) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.host ?? "")
        _port = State(initialValue: existing?.port ?? ManualEndpointParser.defaultPort)
    }

    private var validation: ManualEndpointValidation {
        ManualEndpointParser.validate(host: host, port: port)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("My Mac", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("192.168.1.23 or my-mac.example.net", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField(ManualEndpointParser.defaultPort, text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    if let problem = validation.problem, !host.isEmpty {
                        Text(problem.message).foregroundStyle(.orange)
                    } else {
                        Text("Any address that reaches your Mac works: a local IP, a VPN or Tailscale address, or a public hostname.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Mac" : "Edit Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let endpoint = SavedEndpoint(
                            id: existing?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            host: host,
                            port: port)
                        onSave(endpoint)
                        dismiss()
                    }
                    .disabled(!validation.isValid)
                }
            }
        }
    }
}
