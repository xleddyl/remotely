import SwiftUI

struct ConnectionsSection: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        Section("Connections") {
            listeningRow
            if controller.sessions.isEmpty {
                Label("Open Remotely on your iPhone or iPad and pick this Mac from the list.",
                      systemImage: "iphone.gen3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.sessions) { session in
                SessionRow(session: session, controller: controller)
            }
        }
    }

    private var listeningRow: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(color: controller.listening ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.listening
                     ? "Visible as \"\(controller.advertisedName)\""
                     : "Not reachable yet")
                Text(controller.listenerStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }
}

struct SessionRow: View {
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var statusColor: Color {
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        if !session.linkUp { return .orange }
        if session.status.hasPrefix("Main display") || session.status.hasPrefix("Connected") {
            return .green
        }
        return .orange
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            StatusDot(color: statusColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.name)
                    Text(session.resolution)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(session.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
                .help("Drop this device now. It can connect again from its own screen.")
        }
    }
}
