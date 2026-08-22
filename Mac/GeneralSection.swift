import SwiftUI

struct GeneralSection: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        Section("General") {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Show app in", selection: $controller.presentation) {
                    ForEach(AppPresentation.allCases, id: \.self) { presentation in
                        Text(presentation.label).tag(presentation)
                    }
                }
                if controller.presentation == .background {
                    Text("No menu bar or Dock icon, and streaming keeps running. Open "
                         + "Remotely again from Spotlight or Finder to bring this window back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Lock this Mac when the last device disconnects", isOn: $controller.lockOnDisconnect)
                if controller.lockOnDisconnect {
                    Text("A few seconds after the last connected device disconnects, this Mac's "
                         + "screen is locked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
