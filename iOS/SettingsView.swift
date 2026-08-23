import SwiftUI
import UIKit

// MARK: - Settings / help sheet

struct SettingsView: View {
    @ObservedObject var receiver: PhoneReceiver
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("reserveSafeArea") private var reserveSafeArea = true
    @AppStorage("touchInputMode") private var touchInputMode = "pointer"
    @AppStorage("pointerSpeed") private var pointerSpeed = 1.0
    @AppStorage(StreamQuality.defaultsKey) private var streamQuality = StreamQuality.best.rawValue
    @AppStorage(StreamPrefs.audioDefaultsKey) private var playMacAudio = true
    @AppStorage("appTheme") private var appTheme = "system"

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        NavigationStack {
            Form {
                streamingSection
                displaySection
                appearanceSection
                touchInputSection
                toolbarSection
                analyticsSection
                permissionsSection
                diagnosticsSection
                howToConnectSection
                aboutSection
            }
            .navigationTitle("Remotely")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var streamingSection: some View {
        Section {
            Picker("Quality", selection: $streamQuality) {
                ForEach(StreamQuality.allCases, id: \.self) { quality in
                    Text(quality.label).tag(quality.rawValue)
                }
            }
            .onChange(of: streamQuality) { _ in receiver.sendPrefs() }

            Toggle("Play Mac audio", isOn: $playMacAudio)
                .onChange(of: playMacAudio) { _ in receiver.sendPrefs() }
        } header: {
            Text("Streaming")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle("Fit around the notch and corners", isOn: $reserveSafeArea)
        } header: {
            Text("Display")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("Theme", selection: $appTheme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.menu)
        } header: {
            Text("Appearance")
        }
    }

    private var touchInputSection: some View {
        Section {
            Picker("Mode", selection: $touchInputMode) {
                Text("Touch").tag("direct")
                Text("Trackpad").tag("pointer")
            }
            .pickerStyle(.menu)

            if touchInputMode == "pointer" {
                HStack {
                    Text("Pointer speed")
                    Slider(value: $pointerSpeed, in: 0.5...3.0, step: 0.25)
                    Text(String(format: "%.2gx", pointerSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Touch input")
        } footer: {
            Text("Pointer speed applies to trackpad mode. 1x moves the cursor exactly with your finger.")
        }
    }

    private var toolbarSection: some View {
        Section {
            NavigationLink {
                ToolbarSettingsView()
            } label: {
                Text("Customize toolbar")
            }
        } header: {
            Text("Toolbar")
        }
    }

    private var analyticsSection: some View {
        Section {
            Toggle("Performance overlay", isOn: $showAnalytics)
        } header: {
            Text("Analytics")
        }
    }

    private var permissionsSection: some View {
        Section {
            Button("Open iOS Settings for Remotely") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Permissions")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DiagnosticsLogView()
            } label: {
                Label("Connection log", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Diagnostics")
        }
    }

    private var howToConnectSection: some View {
        Section {
            Label("Open Remotely on your Mac and leave it running. There is nothing to click there.",
                  systemImage: "laptopcomputer")
            Label("On the same WiFi network, pick your Mac from the list and tap Connect.",
                  systemImage: "wifi")
            Label("Away from home, use Connect by address with the Mac's Tailscale or VPN address.",
                  systemImage: "network")
            Label("Tap the floating handle for the keyboard and modifier keys, or the red button to end the session.",
                  systemImage: "slider.horizontal.3")
        } header: {
            Text("How to connect")
        } footer: {
            Text("Rotate the \(deviceKind) at any time for a tall, vertical second monitor.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: version)
            Link(destination: macAppURL) {
                Label("Get the Mac app", systemImage: "arrow.down.circle")
            }
            Link(destination: macAppURL) {
                Label("Source on GitHub", systemImage: "link")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Remotely needs the Mac app running on a Mac you can reach over the network. Download it here if you have not yet.")
        }
    }
}
