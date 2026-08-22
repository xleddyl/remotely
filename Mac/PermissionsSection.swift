import SwiftUI

struct PermissionsSection: View {
    @ObservedObject var controller: SenderController
    @ObservedObject var permissions: PermissionMonitor

    var body: some View {
        Section("Permissions") {
            PermissionRow(
                title: "Screen Recording",
                granted: permissions.screenRecording,
                help: "Needed to capture the screen Remotely sends to your device.",
                anchor: "Privacy_ScreenCapture",
                request: { permissions.requestScreenRecording() }
            )
            PermissionRow(
                title: "Accessibility",
                granted: permissions.accessibility,
                help: "Needed for touch, trackpad and keyboard input from your device.",
                anchor: "Privacy_Accessibility",
                request: { permissions.requestAccessibility() }
            )
            // macOS offers no API to query Local Network access, so
            // infer from live connections and let the user check.
            PermissionRow(
                title: "Local Network",
                granted: !controller.sessions.isEmpty,
                uncertain: controller.sessions.isEmpty,
                help: "Needed so this Mac can be found on the network. If it never shows up "
                    + "in the list on your iPhone or iPad, allow Remotely under Privacy & "
                    + "Security, Local Network, on both.",
                anchor: "Privacy_LocalNetwork"
            )
        }
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    var uncertain = false
    let help: String
    let anchor: String
    var request: (() -> Void)? = nil

    private var symbol: String {
        if uncertain { return "questionmark.circle.fill" }
        return granted ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var symbolColor: Color {
        if uncertain { return .orange }
        return granted ? .green : .red
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already "
                              + "dismissed once, this registers the app under \(title) in "
                              + "System Settings, where you can flip the switch.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}
