import AppKit
import Combine
import Network

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
    }

    @Published var sessions: [DeviceSession] = [] {
        didSet { refreshSessionPolicies() }
    }
    @Published private(set) var listening = false
    @Published private(set) var listenerStatus = "Starting…"

    let advertisedName = PhoneConnectionListener.computerName
    let listenPort = PhoneConnectionListener.port

    @Published var quality = StreamQuality.resolved(
        stored: UserDefaults.standard.string(forKey: StreamQuality.defaultsKey)) {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: StreamQuality.defaultsKey) }
    }
    @Published var lockOnDisconnect = UserDefaults.standard.bool(forKey: "lockOnDisconnect") {
        didSet { UserDefaults.standard.set(lockOnDisconnect, forKey: "lockOnDisconnect") }
    }

    var running: Bool { !sessions.isEmpty }

    private let listener = PhoneConnectionListener()

    private var activeSessionCount: Int { sessions.filter { !$0.failed }.count }
    private var streamingSessionCount: Int {
        sessions.filter { !$0.failed && $0.linkUp }.count
    }
    private var wasHoldingForSessions = false
    private var idleLockGeneration = 0
    private let idleLockDelay: TimeInterval = 3

    private var dismissedUntil: [String: Date] = [:]
    private let dismissalCooldown: TimeInterval = 30

    init() {
        listener.onState = { [weak self] listening, text in
            Task { @MainActor in
                self?.listening = listening
                self?.listenerStatus = text
            }
        }
        listener.onAccepted = { [weak self] accepted in
            Task { @MainActor in self?.accept(accepted) }
        }
        listener.start()
    }

    private func accept(_ accepted: PhoneConnectionListener.Accepted) {
        let id = Self.sessionID(for: accepted.hello)
        if let until = dismissedUntil[id], until > Date() {
            Log.info("\(id) was disconnected here moments ago, refusing until it settles")
            accepted.connection.cancel()
            return
        }
        dismissedUntil[id] = nil

        if let existing = session(for: id) {
            // A failed session holds no pipeline, so replace the corpse instead
            // of letting it swallow the fresh connection.
            if existing.failed {
                end(existing)
            } else {
                Log.info("\(existing.name) reconnected into session \(id)")
                existing.update(hello: accepted.hello)
                existing.sender.adopt(accepted.connection, hello: accepted.hello)
                return
            }
        }
        start(sessionID: id, accepted: accepted)
    }

    private static func sessionID(for hello: PhoneInfo) -> String {
        "device:\(hello.id ?? "legacy")"
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupVirtualDisplay) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    private func start(sessionID id: String, hello: PhoneInfo,
                       accepted: PhoneConnectionListener.Accepted? = nil) {
        let name = hello.kind
        let sender = MacSender(hello: hello, name: name,
                               quality: quality,
                               displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id))
        let session = DeviceSession(id: id, name: name, hello: hello, sender: sender)
        session.linkUp = accepted != nil
        sender.onStatus = { [weak session] text in
            // Retry loops re-announce the same status every second, so only a
            // change is worth the UI churn and the log line.
            guard let session, session.status != text else { return }
            session.status = text
            Log.info("status[\(id)]: \(text)")
        }
        sender.onHello = { [weak session] info in
            session?.update(hello: info)
        }
        sender.onLinkChanged = { [weak self, weak session] up in
            guard let self, let session else { return }
            session.linkUp = up
            self.refreshSessionPolicies()
        }
        sender.onConnected = { [weak self] in
            self?.handleConnected()
        }
        sender.onPrefs = { [weak self] prefs in
            self?.apply(prefs)
        }
        sender.onMainDisplayChanged = { [weak self, weak session] displayID in
            // Record it and recompute — the takeover is never commanded from
            // here, only derived from the sessions that currently exist.
            guard let self, let session else { return }
            session.mainDisplayID = displayID
            self.refreshSessionPolicies()
        }
        sender.onStats = { [weak session] mbps in
            session?.mbps = mbps
        }
        sender.onDisconnected = { [weak self, weak session] in
            // The device stayed away past the reconnect grace: end this
            // session fully (virtual display + capture + indicator). Coming
            // back is the device's call, and it starts a new session.
            guard let self, let session else { return }
            Log.info("device gone, session \(session.id) stopped")
            self.end(session)
        }
        sender.onPeerGoodbye = { [weak self, weak session] in
            // The device locked or the app quit: deliberate, so the display
            // comes down now rather than after the grace window.
            guard let self, let session else { return }
            Log.info("session \(session.id) closed by the device, ending")
            self.end(session)
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI, the same intent as
            // the in-app Disconnect, so it is honored the same way.
            guard let self, let session else { return }
            Log.info("session \(session.id) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let session else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: session.id))
            Log.info("display identity for \(session.id) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sessions.append(session)
        if let accepted {
            sender.adopt(accepted.connection, hello: accepted.hello)
        }
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while it was starting, nothing to report
            } catch {
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connection.
                session.failed = true
                sender.stop()
                self.refreshSessionPolicies()
            }
        }
    }

    private func start(sessionID id: String, accepted: PhoneConnectionListener.Accepted) {
        start(sessionID: id, hello: accepted.hello, accepted: accepted)
    }

    /// User-initiated disconnect from the Mac panel.
    func disconnect(_ session: DeviceSession) {
        dismissedUntil[session.id] = Date().addingTimeInterval(dismissalCooldown)
        end(session)
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    private func end(_ session: DeviceSession) {
        session.sender.stop()
        sessions.removeAll { $0.id == session.id }
    }

    /// Everything that has to be true "while sessions are live" is recomputed
    /// here, from the session list — never latched by a single callback. That
    /// is what makes the paths which bypass `end()` (restartAll, the
    /// failed-start path) put the Mac back exactly like a clean disconnect.
    private func refreshSessionPolicies() {
        refreshPowerPolicy()
        refreshMainDisplayTakeover()
    }

    /// The virtual display that should own the Mac's global origin: the first
    /// live session with the device actually connected. A session in the
    /// reconnect grace keeps its display but gives the origin back, so the
    /// Mac's own screens come back the moment the link drops instead of
    /// staying black for the whole grace window; reconnecting re-asserts the
    /// takeover. Extra devices stay ordinary extra displays: only one screen
    /// can be the main one.
    private var takeoverDisplayID: CGDirectDisplayID? {
        sessions.first { !$0.failed && $0.linkUp && $0.mainDisplayID != nil }?.mainDisplayID
    }

    private func refreshMainDisplayTakeover() {
        let visible = Set(sessions.compactMap { $0.failed ? nil : $0.mainDisplayID })
        MainDisplayTakeover.shared.update(primary: takeoverDisplayID, keepVisible: visible)
    }

    private func refreshPowerPolicy() {
        PowerManager.shared.update(activeSessions: streamingSessionCount)
        let active = activeSessionCount
        if active > 0 {
            wasHoldingForSessions = true
            idleLockGeneration &+= 1
        } else if wasHoldingForSessions {
            wasHoldingForSessions = false
            scheduleIdleLock()
        }
    }

    private func scheduleIdleLock() {
        guard lockOnDisconnect else { return }
        idleLockGeneration &+= 1
        let generation = idleLockGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + idleLockDelay) { [weak self] in
            guard let self, generation == self.idleLockGeneration,
                  self.lockOnDisconnect, self.activeSessionCount == 0 else { return }
            Log.info("last session ended, locking the screen")
            ScreenLocker.lock()
        }
    }

    private func handleConnected() {
        PowerManager.shared.declareUserActivity()
    }

    func apply(_ prefs: StreamPrefs) {
        guard prefs.quality != quality else { return }
        quality = prefs.quality
        restartAll()
    }

    /// Quality applies per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let rebuilds = sessions.map { ($0.id, $0.hello) }
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        for (id, hello) in rebuilds {
            start(sessionID: id, hello: hello)
        }
    }
}
