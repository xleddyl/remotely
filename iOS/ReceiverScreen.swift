import SwiftUI
import UIKit

// MARK: - Root screen

struct ReceiverScreen: View {
    @StateObject private var model = ReceiverModel()
    @State private var showSettings = false
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reserveSafeArea") private var reserveSafeArea = true
    @AppStorage("screenSizeMode") private var screenSizeMode = "phone"
    // First-run onboarding (issue #49): explain the Mac app is required.
    // Shown until either the user dismisses it or the device connects once.
    @AppStorage("hasConnectedBefore") private var hasConnectedBefore = false
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false

    // Streaming = connected and the video format is known.
    private var isStreaming: Bool {
        model.receiver.connected && model.receiver.videoSize != .zero
    }

    private var videoInsets: EdgeInsets {
        guard reserveSafeArea else { return EdgeInsets() }
        let insets = model.receiver.panelInsets
        return EdgeInsets(top: insets.top, leading: insets.left,
                          bottom: insets.bottom, trailing: insets.right)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isStreaming {
                    StreamingLayout(receiver: model.receiver,
                                    input: model.input,
                                    safeArea: geo.safeAreaInsets,
                                    videoInsets: videoInsets,
                                    openSettings: { showSettings = true },
                                    disconnect: { model.disconnect() })
                } else if model.receiver.isIdle {
                    IdleView(model: model, receiver: model.receiver,
                             browser: model.browser, showSettings: $showSettings)
                } else {
                    ConnectingView(receiver: model.receiver,
                                   cancel: { model.disconnect() })
                }
            }
            .onAppear {
                model.receiver.setOrientation(portrait: geo.size.height > geo.size.width)
                syncWindowSafeArea()
            }
            .onChange(of: geo.size) { size in
                model.receiver.setOrientation(portrait: size.height > size.width)
                syncWindowSafeArea()
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView { onboardingDismissed = true }
            }
        }
        .ignoresSafeArea(edges: isStreaming ? .all : [])
        .statusBarHidden(isStreaming)
        .persistentSystemOverlays(isStreaming ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView(receiver: model.receiver)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            showSettings = true
        }
        .onChange(of: scenePhase) { phase in
            Log.info("scenePhase -> \(String(describing: phase))")
            switch phase {
            case .active: model.sceneDidActivate()
            case .background: model.sceneDidBackground()
            default: break
            }
        }
        // The deliberate "screen off" signal: locking the device makes
        // protected data unavailable (a plain app switch doesn't). This is
        // what separates "put the iPhone to sleep — end the session now"
        // from "peeked at a message — keep the session alive".
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            Log.info("protected data will become unavailable (device locking)")
            model.deviceWillLock()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            Log.info("protected data available again (device unlocked)")
            model.deviceDidUnlock()
        }
        // Swiping the app away in the switcher (while we're still running)
        // grants a ~5s notice — enough for a clean goodbye so the Mac ends
        // the session at once. A kill without notice is covered Mac-side:
        // dead apps stop accepting redials, so the silence grace fires.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification)) { _ in
            model.appWillTerminate()
        }
        .onChange(of: reserveSafeArea) { model.receiver.setReserveSafeArea($0) }
        .onChange(of: screenSizeMode) { model.receiver.setScreenSizeMode($0) }
        .onChange(of: model.receiver.macSupportsKeyboardWire) { supported in
            if !supported { model.input.reset() }
        }
        .onChange(of: isStreaming) { streaming in
            if !streaming { model.input.reset() }
        }
        .onChange(of: model.receiver.connected) { isConnected in
            // The first valid connection retires the onboarding hint for good.
            if isConnected {
                hasConnectedBefore = true
                showOnboarding = false
            } else {
                model.connectionDidEnd()
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
            model.sceneDidActivate()
            // Show the first-run hint unless the device has connected before
            // or the user already dismissed it.
            if !hasConnectedBefore && !onboardingDismissed {
                showOnboarding = true
            }
        }
    }

    private func syncWindowSafeArea() {
        DispatchQueue.main.async {
            model.receiver.setWindowSafeArea(keyWindowSafeAreaInsets())
        }
    }
}

private struct StreamingLayout: View {

    @ObservedObject var receiver: PhoneReceiver
    @ObservedObject var input: InputController
    let safeArea: EdgeInsets
    let videoInsets: EdgeInsets
    let openSettings: () -> Void
    let disconnect: () -> Void

    @AppStorage("showAnalytics") private var showAnalytics = false
    @State private var perfOverlayHeight: CGFloat = 0
    @State private var keyboardHeight: CGFloat = 0
    @State private var windowInsets = UIEdgeInsets.zero
    @State private var inputBarHeight: CGFloat = 0

    private static let keyboardWillChange = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillChangeFrameNotification)
    private static let keyboardWillHide = NotificationCenter.default
        .publisher(for: UIResponder.keyboardWillHideNotification)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                videoArea
                if input.expanded {
                    DockedInputBar(controller: input,
                                   supported: receiver.macSupportsKeyboardWire,
                                   bottomInset: barBottomInset,
                                   collapse: collapse,
                                   openSettings: openSettings,
                                   disconnect: disconnect)
                        .background(
                            GeometryReader { barGeo in
                                Color.clear.preference(key: DockedInputBarHeightKey.self,
                                                       value: barGeo.size.height)
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, keyboardHeight)
            if !input.expanded {
                InputToolbar(controller: input,
                             supported: receiver.macSupportsKeyboardWire,
                             safeArea: safeArea,
                             keyboardHeight: keyboardHeight,
                             bottomObstruction: showAnalytics ? perfOverlayHeight : 0)
            }
        }
        .onPreferenceChange(PerfOverlayHeightKey.self) { perfOverlayHeight = $0 }
        .onPreferenceChange(DockedInputBarHeightKey.self) { inputBarHeight = $0 }
        .onAppear {
            refreshWindowInsets()
            receiver.setBottomObstruction(bottomObstruction)
        }
        .onDisappear { receiver.setBottomObstruction(0) }
        .onChange(of: bottomObstruction) { receiver.setBottomObstruction($0) }
        .onChange(of: safeArea) { _ in refreshWindowInsets() }
        .onReceive(Self.keyboardWillChange) { note in
            refreshWindowInsets()
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = UIApplication.shared.connectedScenes
                      .compactMap({ $0 as? UIWindowScene }).first?.screen.bounds else { return }
            setKeyboardHeight(max(0, screen.maxY - end.minY), from: note)
        }
        .onReceive(Self.keyboardWillHide) { note in setKeyboardHeight(0, from: note) }
    }

    private var videoArea: some View {
        ZStack {
            VideoLayerView(displayLayer: receiver.displayLayer,
                           receiver: receiver,
                           input: input)
                .padding(videoInsets)
            if showAnalytics {
                VStack {
                    Spacer()
                    PerfOverlay(stats: receiver.perf, videoSize: receiver.videoSize)
                        .padding(.bottom, 10)
                        .background(
                            GeometryReader { overlayGeo in
                                Color.clear.preference(key: PerfOverlayHeightKey.self,
                                                       value: overlayGeo.size.height)
                            }
                        )
                }
                .allowsHitTesting(false)   // never block touch input
            }
        }
    }

    private var bottomObstruction: CGFloat {
        keyboardHeight + (input.expanded ? inputBarHeight : 0)
    }

    private var barBottomInset: CGFloat {
        guard keyboardHeight <= 0 else { return 0 }
        return max(safeArea.bottom, windowInsets.bottom)
    }

    private func collapse() {
        withAnimation(ToolbarMotion.expand) { input.expanded = false }
    }

    private func setKeyboardHeight(_ height: CGFloat, from note: Notification) {
        guard keyboardHeight != height else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        withAnimation(.easeOut(duration: max(duration ?? 0.25, 0.1))) {
            keyboardHeight = height
        }
    }

    private func refreshWindowInsets() {
        DispatchQueue.main.async { windowInsets = keyWindowSafeAreaInsets() }
    }
}
