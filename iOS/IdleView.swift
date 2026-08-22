import SwiftUI

struct GroupedCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct GroupedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color(.systemFill) : Color.clear)
    }
}

struct GroupedSectionHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupedSectionFooter<Tint: ShapeStyle>: View {
    let text: String
    var tint: Tint

    init(text: String, tint: Tint) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension GroupedSectionFooter where Tint == HierarchicalShapeStyle {
    init(text: String) {
        self.init(text: text, tint: .secondary)
    }
}

struct GroupedRowDivider: View {
    var inset: CGFloat = 57

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(Color(red: 78/255, green: 117/255, blue: 1.0))
                .frame(width: size * 65/84, height: size * 65/84)
            Circle()
                .fill(Color(red: 10/255, green: 22/255, blue: 83/255))
                .frame(width: size * 65/84, height: size * 65/84)
                .offset(x: size * 19/84, y: size * 19/84)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Idle view (no Mac connected), regular iOS look, follows light/dark

struct IdleView: View {
    let model: ReceiverModel
    @ObservedObject var receiver: PhoneReceiver
    @ObservedObject var browser: MacBrowser
    @Binding var showSettings: Bool

    @AppStorage("manualHost") private var manualHost = ""
    @AppStorage("manualPort") private var manualPort = ManualEndpointParser.defaultPort
    @State private var showAddressFields = false

    private var validation: ManualEndpointValidation {
        ManualEndpointParser.validate(host: manualHost, port: manualPort)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                macList
                addressSection
                footer
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 36)
        }
        .refreshable {
            browser.refresh()
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            Text("Remotely")
                .font(.custom("MontserratAlternates-Bold", size: 30, relativeTo: .largeTitle))
            Spacer(minLength: 8)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings")
        }
    }

    private var macList: some View {
        VStack(spacing: 0) {
            GroupedSectionHeader(text: "Macs on this network")
            GroupedCard {
                if browser.macs.isEmpty {
                    searchingRow
                } else {
                    ForEach(Array(browser.macs.enumerated()), id: \.element.id) { index, mac in
                        if index > 0 { GroupedRowDivider(inset: 52) }
                        macRow(mac)
                    }
                }
            }
        }
    }

    private var searchingRow: some View {
        HStack(spacing: 12) {
            Group {
                if browser.searching {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, alignment: .leading)

            Text("Open Remotely on your Mac to see it here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func macRow(_ mac: DiscoveredMac) -> some View {
        Button {
            model.connect(to: mac)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.body.weight(.regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .leading)
                Text(mac.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(GroupedRowButtonStyle())
        .disabled(!receiver.isIdle)
        .accessibilityLabel("Connect to \(mac.name)")
    }

    private var addressSection: some View {
        VStack(spacing: 0) {
            GroupedSectionHeader(text: "Away from home")
            GroupedCard {
                disclosureRow
                if showAddressFields {
                    GroupedRowDivider()
                    hostField
                    GroupedRowDivider(inset: 16)
                    portField
                }
            }
            if showAddressFields {
                if let problem = validation.problem, !manualHost.isEmpty {
                    GroupedSectionFooter(text: problem.message, tint: Color.orange)
                } else {
                    GroupedSectionFooter(
                        text: "Reach your Mac over Tailscale or a VPN when it is not on this network.")
                }

                Button {
                    model.connectManual(host: manualHost, port: manualPort)
                } label: {
                    Text("Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!validation.isValid || !receiver.isIdle)
                .padding(.top, 16)
            }
        }
    }

    private var disclosureRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showAddressFields.toggle() }
        } label: {
            HStack(spacing: 12) {
                Text("Connect by address")
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showAddressFields ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(GroupedRowButtonStyle())
        .accessibilityLabel("Connect by address")
        .accessibilityHint(showAddressFields ? "Hides the address fields" : "Shows the address fields")
    }

    private var hostField: some View {
        TextField("mac.tailnet-name.ts.net", text: $manualHost)
            .font(.body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityLabel("Mac address")
    }

    private var portField: some View {
        HStack(spacing: 12) {
            Text("Port")
                .font(.body)
            TextField(ManualEndpointParser.defaultPort, text: $manualPort)
                .font(.body)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Port")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        Text("Shake your \(deviceKind) to open settings anytime")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}

// MARK: - Connecting (dialing, or connected but no picture yet)

struct ConnectingView: View {
    @ObservedObject var receiver: PhoneReceiver
    let cancel: () -> Void

    private var headline: String {
        receiver.connected
            ? "Waiting for the picture"
            : "Connecting to \(receiver.macName ?? "your Mac")"
    }

    private var detail: String {
        receiver.connected
            ? "Your Mac is setting up the display and starting the video stream. This takes a few seconds."
            : receiver.status
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 96, height: 96)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 28)

            VStack(spacing: 8) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 20)
            .animation(.easeInOut(duration: 0.2), value: receiver.connected)

            Spacer()

            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - First-run onboarding (the Mac app is required to connect)

/// Shown on first launch / while the device has never connected: Remotely
/// is two apps, and the iOS side is useless without the Mac app running.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let onClose: () -> Void

    private var steps: [SetupStep] {
        [SetupStep(symbol: "1.circle.fill",
                   text: "Install the Remotely Mac app and open it"),
         SetupStep(symbol: "2.circle.fill",
                   text: "Join the same WiFi network, or reach the Mac over Tailscale"),
         SetupStep(symbol: "3.circle.fill",
                   text: "Pick the Mac here and tap Connect. Next time it reconnects on its own")]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tint)
                        .frame(width: 104, height: 104)
                        .background(Color(.secondarySystemGroupedBackground), in: Circle())
                        .padding(.top, 12)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("One more app to go")
                            .font(.title2.bold())
                        Text("Remotely turns this \(deviceKind) into a second screen for your Mac. It needs the **Remotely Mac app** running on a Mac you can reach over the same WiFi network, or by address over Tailscale or a VPN.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                    SetupStepList(steps: steps)
                        .padding(.top, 28)

                    Link(destination: macAppURL) {
                        Label("Get the Mac app", systemImage: "arrow.down.circle")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 28)

                    Text("This link stays in Settings. Shake your \(deviceKind) to open it.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                }
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        onClose()
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SetupStep: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
}

struct SetupStepList: View {
    let steps: [SetupStep]

    var body: some View {
        GroupedCard {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { GroupedRowDivider(inset: 52) }
                HStack(alignment: .center, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor.gradient, in: Circle())
                        .accessibilityHidden(true)
                    Text(step.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }
}
