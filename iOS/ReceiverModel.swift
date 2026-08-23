import AVFoundation
import Combine
import Network
import UIKit

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    let receiver: PhoneReceiver
    let browser = MacBrowser()
    let input = InputController()
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var active = false

    init() {
        receiver = PhoneReceiver(displayLayer: AVSampleBufferDisplayLayer())
        input.receiver = receiver
        // Announce the native panel size to the Mac.
        let native = UIScreen.main.nativeBounds.size   // portrait pixels
        receiver.setNativePanel(long: Int(max(native.width, native.height)),
                                short: Int(min(native.width, native.height)),
                                scale: Double(UIScreen.main.nativeScale))
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        receiver.$dialing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dialing in self?.resumeDialFinished(stillDialing: dialing) }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        receiver.start()
    }

    func connect(to mac: DiscoveredMac) {
        currentEndpoint = mac.endpoint
        browser.stop()
        receiver.connect(to: mac.endpoint, name: mac.name)
    }

    func connectManual(host: String, port: String) {
        guard let endpoint = ManualEndpointParser.endpoint(host: host, port: port),
              let nwPort = NWEndpoint.Port(rawValue: endpoint.port) else { return }
        let target = NWEndpoint.hostPort(host: NWEndpoint.Host(endpoint.host), port: nwPort)
        currentEndpoint = target
        browser.stop()
        receiver.connect(to: target, name: endpoint.host)
    }

    func connect(to endpoint: SavedEndpoint) {
        connectManual(host: endpoint.host, port: endpoint.port)
    }

    private struct InterruptedSession {
        let endpoint: NWEndpoint
        let name: String
        let at: Date
    }
    private var interruptedSession: InterruptedSession?
    private var currentEndpoint: NWEndpoint?
    private var resumingInterrupted = false
    private let resumeWindow: TimeInterval = 10 * 60

    @discardableResult
    private func resumeInterruptedSessionIfNeeded() -> Bool {
        guard let session = interruptedSession else { return false }
        interruptedSession = nil
        guard receiver.isIdle, Date().timeIntervalSince(session.at) < resumeWindow else { return false }
        Log.info("resuming interrupted session with \"\(session.name)\"")
        currentEndpoint = session.endpoint
        resumingInterrupted = true
        browser.stop()
        receiver.connect(to: session.endpoint, name: session.name)
        return true
    }

    private func resumeDialFinished(stillDialing: Bool) {
        guard resumingInterrupted, !stillDialing else { return }
        resumingInterrupted = false
        if !receiver.connected { refreshBrowsing() }
    }

    private func refreshBrowsing() {
        if active, receiver.isIdle {
            browser.start()
        } else {
            browser.stop()
        }
    }

    // MARK: - Lock vs app switch vs app quit

    // The device dials, so a suspended app means a dead socket. That is fine:
    // the Mac keeps the virtual display (and therefore the user's window
    // arrangement) standing for its reconnect grace window, and coming back to
    // the app reconnects into it. A device lock or the app being quit is a
    // deliberate goodbye, which ends the session on the Mac at once.
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBackground() {
        active = false
        browser.stop()
        // Known limitation: lock detection rides the protected-data signal,
        // which only fires when a passcode is set AND "Require Passcode" is
        // Immediately (the Face ID default). Other configurations make a
        // lock indistinguishable from an app switch, so those keep the
        // session like a backgrounded app would.
        if !UIApplication.shared.isProtectedDataAvailable {
            // Backgrounded because the device locked, not an app switch.
            Log.info("backgrounded by device lock — sleeping now")
            interruptedSession = nil
            goToSleep()
            return
        }
        Log.info("app switched away, rendering paused")
        if receiver.connected, let endpoint = currentEndpoint, let name = receiver.macName {
            interruptedSession = InterruptedSession(endpoint: endpoint, name: name, at: Date())
        }
        beginBackgroundAssertion()
        receiver.setRenderingPaused(true)
    }

    func sceneDidActivate() {
        active = true
        endBackgroundAssertion()
        receiver.setRenderingPaused(false)
        if !resumeInterruptedSessionIfNeeded() {
            refreshBrowsing()
        }
    }

    func deviceWillLock() {
        Log.info("device locking — sleeping now")
        interruptedSession = nil
        goToSleep()
    }

    /// Unlock arrives via the protected-data notification, which also fires
    /// when the user unlocks into ANOTHER app while we sit in the background,
    /// so don't start browsing or unpause rendering off-screen there; the real
    /// return still comes through scenePhase.
    func deviceDidUnlock() {
        guard UIApplication.shared.applicationState == .active else {
            Log.info("unlocked while backgrounded — staying dormant")
            return
        }
        sceneDidActivate()
    }

    /// User swiped the app away (or iOS terminates us while still running):
    /// ~5s of runtime remain, plenty for the "closing" goodbye that lets the
    /// Mac end the session immediately instead of holding its display.
    func appWillTerminate() {
        Log.info("app terminating — closing session")
        interruptedSession = nil
        let sent = DispatchSemaphore(value: 0)
        receiver.shutDown { sent.signal() }
        _ = sent.wait(timeout: .now() + 2)
    }

    func disconnect() {
        Log.info("user ended the session from the toolbar")
        interruptedSession = nil
        receiver.shutDown()
    }

    func connectionDidEnd() {
        refreshBrowsing()
    }

    private func goToSleep() {
        receiver.enterSleep { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundAssertion() }
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundToken)
        backgroundToken = .invalid
    }
}
