import SwiftUI

struct ContentView: View {
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 500

    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                ConnectionsSection(controller: controller)
                GeneralSection(controller: controller)
                PermissionsSection(controller: controller, permissions: permissions)
            }
            .formStyle(.grouped)
            // Scrollable + fixed panel height: MenuBarExtra windows mis-measure
            // grouped Forms (clipping on small displays), so size explicitly
            // and let the form scroll when it doesn't fit.

            Divider()

            statusBar
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remotely")
                    .font(.title3.bold())
                Text("Your iPad or iPhone as an extra Mac display")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.running {
                Button("Disconnect All") { controller.disconnectAll() }
                    .controlSize(.large)
            }
        }
        .padding(16)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            StatusDot(color: controller.running ? .green : .secondary.opacity(0.5))
            Text(connectionSummary)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            // Support affordance: bug reports are much easier to act on
            // with the log attached, and users shouldn't have to be told a
            // filesystem path to find it.
            Button("Logs") { Log.revealInFinder() }
                .controlSize(.small)
                .help("Reveal the Remotely log files in Finder")
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var connectionSummary: String {
        let count = controller.sessions.count
        guard count > 0 else {
            return controller.listening
                ? "Waiting for a device on port \(controller.listenPort)"
                : "Not reachable yet"
        }
        return "\(count) device\(count == 1 ? "" : "s") connected"
    }
}

/// The dot that fronts every device row and the status bar.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }
}
