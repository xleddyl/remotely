// PhoneReceiver — Milestone 1: receive H.264 over TCP and display it.
//
// Pipeline:  TCP socket -> deframe -> Annex B parse -> CMSampleBuffer
//            -> AVSampleBufferDisplayLayer (decodes + renders)
//
// The MAC listens and advertises itself; this app dials the Mac the user
// picked and sends `hello` first.
// Wire protocol: [4-byte big-endian length][Annex B payload].

import Foundation
import Network
import AVFoundation
import CoreMedia
import UIKit

/// One-second window of pipeline health, plus per-frame timing samples for
/// the performance overlay graph.
struct PerfStats: Equatable {
    var fps = 0
    var mbps = 0.0
    var stalls = 0               // frames that arrived >50ms late (this window)
    var decodeFlushes = 0        // display layer failures since connect
    var samples: [Double] = []   // last ~120 inter-frame intervals, ms
    // True end-to-end latency (Mac capture → phone display handoff), using
    // the clock offset estimated from timestamped ping/pong.
    var e2eP50 = 0.0
    var e2eP95 = 0.0
    var encodeP50 = 0.0          // Mac-side capture→socket (encode + queue)
    var rttMs = 0.0              // control-channel round trip
    var e2eSamples: [Double] = []  // last ~120 per-frame e2e latencies, ms
    var transport = "—"          // how the Mac is reached
    var macEncDrops = 0          // Mac skipped capture: encoder busy
    var macNetDrops = 0          // Mac skipped capture: TCP queue full
    var macPending = 0           // Mac send queue depth right now
    var inputP50 = 0.0           // touch sent → CGEvent injected on the Mac, ms
    var capFps = 0               // frames ScreenCaptureKit delivered on the Mac
}

final class PhoneReceiver: ObservableObject {

    @Published var status = "Not connected"
    @Published var fps = 0
    @Published var connected = false
    @Published private(set) var dialing = false
    @Published private(set) var macName: String?

    var isIdle: Bool { !connected && !dialing }

    static let serviceType = "_remotely._tcp"
    static let defaultPort: UInt16 = 9000
    @Published var videoSize = CGSize.zero   // for touch coordinate mapping
    @Published var perf = PerfStats()
    /// Mac protocol version from the most recent `welcome` message.
    @Published private(set) var macProtocolVersion = WireProtocol.assumedWhenAbsent

    /// True when the connected Mac understands pencil/proximity wire messages.
    var macSupportsPencilWire: Bool { macProtocolVersion >= WireProtocol.pencilWireVersion }

    var macSupportsKeyboardWire: Bool { macProtocolVersion >= WireProtocol.keyboardWireVersion }

    var macSupportsMacSizeWire: Bool { macProtocolVersion >= WireProtocol.macSizeWireVersion }

    @Published private(set) var panelInsets = UIEdgeInsets.zero
    private var queuePanelInsets = UIEdgeInsets.zero
    private var reserveSafeArea = UserDefaults.standard.object(forKey: "reserveSafeArea") as? Bool ?? true
    private var screenSizeMode = UserDefaults.standard.string(forKey: "screenSizeMode") ?? "phone"
    private var bottomObstruction: CGFloat = 0

    private var connection: NWConnection?
    private var dialGeneration = 0
    private let queue = DispatchQueue(label: "receiver.video")
    private var buffer = Data()
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    // Liveness: the Mac streams video and pings every 2s; if nothing arrives
    // for 5s the connection is half-open (Mac quit, network dropped), so drop
    // it and dial a fresh one.
    private var lastDataReceived = Date()
    private var monitorsStarted = false

    private var framesThisWindow = 0
    private var fpsWindowStart = Date()
    private var bytesThisWindow = 0
    private var stallsThisWindow = 0
    private var decodeFlushes = 0
    private var lastFrameAt: Date?
    private var frameIntervals: [Double] = []   // ring buffer, ms
    private let maxSamples = 120

    // Clock sync (NTP-style): offset = macClock − phoneClock, taken from the
    // ping/pong sample with the lowest RTT (least asymmetric).
    private var offsetSamples: [(rtt: Double, offset: Double)] = []
    private var clockOffsetMs: Double?
    private var lastRttMs = 0.0
    private var e2eWindow: [Double] = []        // capture→display, ms
    private var encodeWindow: [Double] = []     // capture→socket on the Mac, ms
    private var e2eRing: [Double] = []          // per-frame, for the overlay graph
    private var statsReportCounter = 0
    private var transport = "—"
    private var macEncDrops = 0
    private var macNetDrops = 0
    private var macPending = 0
    private var macInputP50 = 0.0
    private var macCapFps = 0

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    // Local cursor echo (both called on the main thread): position is
    // normalized [0,1] in video space; the sprite arrives as a PNG with its
    // hotspot anchor and size normalized against the Mac display.
    var onCursor: ((_ x: Double, _ y: Double, _ visible: Bool) -> Void)?
    var onCursorImage: ((_ image: UIImage, _ anchor: CGPoint, _ normSize: CGSize) -> Void)?
    var onDisconnect: (() -> Void)?

    let displayLayer: AVSampleBufferDisplayLayer
    private let audio = AudioPlayer()

    /// Native panel size in pixels + scale, announced to the Mac in a "hello"
    /// message so it can size the virtual display. Orientation-dependent:
    /// rotating the phone re-announces with swapped dimensions and the Mac
    /// rebuilds the virtual display as a portrait/landscape monitor.
    private var nativeLong = 0
    private var nativeShort = 0
    private(set) var devicePixelsWide = 0
    private(set) var devicePixelsHigh = 0
    var deviceScale: Double = 2

    // Stable per-install identity, sent in every hello. The Mac keys its
    // session on it, so a reconnect from this device resumes into the display
    // and window arrangement it left behind.
    static let installID: String = {
        if let existing = UserDefaults.standard.string(forKey: "installID") {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "installID")
        return fresh
    }()

    func setNativePanel(long: Int, short: Int, scale: Double) {
        nativeLong = long
        nativeShort = short
        deviceScale = scale
        if devicePixelsWide == 0 {   // default landscape until the view reports
            devicePixelsWide = long
            devicePixelsHigh = short
        }
    }

    func setOrientation(portrait: Bool) {
        queue.async {
            let w = portrait ? self.nativeShort : self.nativeLong
            let h = portrait ? self.nativeLong : self.nativeShort
            guard w > 0, w != self.devicePixelsWide else { return }
            self.devicePixelsWide = w
            self.devicePixelsHigh = h
            Log.info("orientation changed -> \(portrait ? "portrait" : "landscape") \(w)x\(h)")
            if let connection = self.connection { self.sendHello(on: connection) }
        }
    }

    func setWindowSafeArea(_ insets: UIEdgeInsets) {
        queue.async {
            guard insets != self.queuePanelInsets else { return }
            self.queuePanelInsets = insets
            DispatchQueue.main.async { self.panelInsets = insets }
            let panel = self.announcedPanel
            Log.info("panel safe area -> top \(insets.top) left \(insets.left)"
                     + " bottom \(insets.bottom) right \(insets.right)"
                     + " announcing \(panel.width)x\(panel.height)")
            if let connection = self.connection { self.sendHello(on: connection) }
        }
    }

    func setReserveSafeArea(_ enabled: Bool) {
        queue.async {
            guard self.reserveSafeArea != enabled else { return }
            self.reserveSafeArea = enabled
            let panel = self.announcedPanel
            Log.info("reserve safe area -> \(enabled), announcing \(panel.width)x\(panel.height)")
            if let connection = self.connection { self.sendHello(on: connection) }
        }
    }

    func setScreenSizeMode(_ mode: String) {
        queue.async {
            guard self.screenSizeMode != mode else { return }
            self.screenSizeMode = mode
            let panel = self.announcedPanel
            Log.info("screen size mode -> \(mode), announcing \(panel.width)x\(panel.height)")
            if let connection = self.connection { self.sendHello(on: connection) }
        }
    }

    func setBottomObstruction(_ points: CGFloat) {
        queue.async {
            guard self.bottomObstruction != points else { return }
            self.bottomObstruction = points
            let panel = self.announcedPanel
            Log.info("bottom obstruction -> \(points), announcing \(panel.width)x\(panel.height)")
            if let connection = self.connection { self.sendHello(on: connection) }
        }
    }

    private var isPortrait: Bool { devicePixelsHigh > devicePixelsWide }

    private var announcedPanel: (width: Int, height: Int) {
        guard screenSizeMode != "mac" else { return (devicePixelsWide, devicePixelsHigh) }
        var width = devicePixelsWide
        var height = devicePixelsHigh
        if reserveSafeArea {
            width -= Int(((queuePanelInsets.left + queuePanelInsets.right) * deviceScale).rounded())
            height -= Int(((queuePanelInsets.top + queuePanelInsets.bottom) * deviceScale).rounded())
        }
        if isPortrait {
            height -= Int((bottomObstruction * deviceScale).rounded())
        }
        width = max(2, width)
        height = max(2, height)
        return (width - width % 2, height - height % 2)
    }

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        displayLayer.videoGravity = .resizeAspect
    }

    func start() {
        guard !monitorsStarted else { return }
        monitorsStarted = true
        schedulePing()
        scheduleWatchdog()
    }

    func connect(to endpoint: NWEndpoint, name: String) {
        queue.async {
            self.dialGeneration += 1
            let generation = self.dialGeneration
            self.connection?.cancel()
            self.connection = nil
            self.resetStreamState()
            self.transport = "WiFi"
            self.setDialing(true, macName: name)
            self.setStatus("Connecting to \(name)…")
            Log.info("dialing \(name) at \(String(describing: endpoint))")

            // noDelay matters most in THIS direction: touch events are tiny
            // packets, and Nagle would hold each one until the previous is
            // ACKed, so drags arrive batched and late, reading as input lag.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.serviceClass = .interactiveVideo
            let conn = NWConnection(to: endpoint, using: params)
            self.connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self, generation == self.dialGeneration else { return }
                switch state {
                case .ready:
                    self.lastDataReceived = Date()
                    self.setDialing(false, macName: name)
                    self.setConnected(true)
                    self.setStatus("Connected to \(name)")
                    self.sendHello(on: conn)
                case .failed(let error):
                    Log.info("connection to \(name) failed: \(error)")
                    self.dropConnection(status: "\(name) did not answer")
                case .cancelled:
                    break
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
            self.receive(on: conn)
            self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, generation == self.dialGeneration,
                      self.connection === conn, conn.state != .ready else { return }
                Log.info("dial to \(name) timed out in \(conn.state)")
                self.dropConnection(status: "\(name) did not answer")
            }
        }
    }

    private func dropConnection(status: String) {
        dialGeneration += 1
        audio.stop()
        connection?.cancel()
        connection = nil
        setDialing(false, macName: nil)
        setConnected(false)
        setStatus(status)
    }

    // Set while the app lingers in the background with the session alive
    // (brief app switch): decoding is pointless and hardware decode sessions
    // fail off-screen, so frames are dropped before the sample stage.
    private var renderingPaused = false

    /// Pause/resume the video sink around a background linger. Resuming
    /// flushes the layer and asks the Mac for a keyframe so the picture
    /// re-syncs immediately (the Mac replays a static screen as IDR too).
    func setRenderingPaused(_ paused: Bool) {
        queue.async {
            guard paused != self.renderingPaused else { return }
            self.renderingPaused = paused
            Log.info(paused ? "rendering paused (backgrounded)" : "rendering resumed")
            if paused {
                self.audio.suspend()
            } else {
                self.audio.resume()
            }
            if !paused {
                self.displayLayer.flush()
                if self.connection?.state == .ready {
                    self.sendControl(["type": "kf"])
                }
            }
        }
    }

    /// The device locked — nobody can see the stream, so tell the Mac and go
    /// silent. "sleeping" is a goodbye: the Mac tears its virtual display down
    /// at once instead of holding it for the reconnect grace, so the cursor
    /// isn't stranded on an invisible screen.
    func enterSleep(completion: (() -> Void)? = nil) {
        closeSession(announcing: WireMessage.sleeping,
                     status: "Asleep, reconnects on wake", completion: completion)
    }

    /// The app is being terminated (user swiped it away). Same close,
    /// announced as "closing".
    func shutDown(completion: (() -> Void)? = nil) {
        closeSession(announcing: WireMessage.closing,
                     status: "Closed", completion: completion)
    }

    private func closeSession(announcing type: String, status: String,
                              completion: (() -> Void)?) {
        queue.async {
            var finished = false
            let finish = { [weak self] in
                guard let self, !finished else { return }
                finished = true
                self.dropConnection(status: status)
                completion?()
            }
            guard let conn = self.connection, conn.state == .ready else {
                Log.info("closing session (\(type)) — no live connection")
                finish()
                return
            }
            Log.info("closing session — announcing \(type) to the Mac")
            self.sendControl(["type": type], on: conn) {
                self.queue.async { finish() }
            }
            // The send completion may never fire on a dying link, so don't let
            // that keep the socket open after we have gone dark.
            self.queue.asyncAfter(deadline: .now() + 1) { finish() }
        }
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if self.connection?.state == .ready {
                self.sendControl(["type": "ping", "t": self.nowMs])
            }
            self.schedulePing()
        }
    }

    /// JSON on the video channel (pong, ping liveness) — payloads starting '{'.
    private func handleVideoChannelJSON(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "pong":
            guard let t1 = obj["t"] as? Double, let mt = obj["mt"] as? Double else { return }
            let t2 = nowMs
            let rtt = t2 - t1
            guard rtt >= 0, rtt < 2000 else { return }
            let offset = mt - (t1 + t2) / 2
            offsetSamples.append((rtt, offset))
            if offsetSamples.count > 15 { offsetSamples.removeFirst() }
            if let best = offsetSamples.min(by: { $0.rtt < $1.rtt }) {
                clockOffsetMs = best.offset
            }
            lastRttMs = rtt
        case "ping":
            // The Mac piggybacks its send-side health on liveness pings.
            if let enc = obj["encDrops"] as? Int {
                macEncDrops = enc
            } else if let drops = obj["drops"] as? Int {
                macEncDrops = drops
            }
            if let net = obj["netDrops"] as? Int {
                macNetDrops = net
            }
            macPending = obj["pending"] as? Int ?? macPending
            macInputP50 = obj["inp50"] as? Double ?? macInputP50
            macCapFps = obj["capFps"] as? Int ?? macCapFps
        case "cursor":
            let visible = (obj["v"] as? Int ?? 0) == 1
            let x = obj["x"] as? Double ?? 0
            let y = obj["y"] as? Double ?? 0
            DispatchQueue.main.async { self.onCursor?(x, y, visible) }
        case "cursorImg":
            guard let b64 = obj["png"] as? String,
                  let png = Data(base64Encoded: b64),
                  let image = UIImage(data: png),
                  let nw = obj["nw"] as? Double, let nh = obj["nh"] as? Double else { return }
            let anchor = CGPoint(x: obj["ax"] as? Double ?? 0, y: obj["ay"] as? Double ?? 0)
            let normSize = CGSize(width: nw, height: nh)
            DispatchQueue.main.async { self.onCursorImage?(image, anchor, normSize) }
        case WireMessage.welcome:
            // The Mac identified itself (issue #132): its protocol version
            // gates the pencil/keyboard wire features.
            let macPV = obj["pv"] as? Int ?? WireProtocol.assumedWhenAbsent
            DispatchQueue.main.async {
                self.macProtocolVersion = macPV
            }
            sendPrefs()
        case WireMessage.audioStart:
            let rate = obj["rate"] as? Double ?? 48_000
            let channels = obj["ch"] as? Int ?? 2
            let cookie = (obj["cookie"] as? String).flatMap { Data(base64Encoded: $0) }
            audio.start(sampleRate: rate, channels: channels, cookie: cookie)
        case WireMessage.audio:
            guard let payload = obj["d"] as? String, let sequence = obj["seq"] as? Int else { return }
            audio.play(sequence: sequence, base64: payload)
        default:
            break
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            if let conn = self.connection, conn.state == .ready,
               Date().timeIntervalSince(self.lastDataReceived) > 5 {
                Log.info("watchdog: nothing from the Mac for >5s — dropping connection")
                self.dropConnection(status: "Connection lost")
            }
            self.scheduleWatchdog()
        }
    }

    private func resetStreamState() {
        audio.stop()
        buffer.removeAll(keepingCapacity: true)
        formatDesc = nil
        sps = nil
        pps = nil
        lastFrameAt = nil
        frameIntervals.removeAll()
        decodeFlushes = 0
        displayLayer.flush()
    }

    // MARK: - Control messages (phone -> Mac)

    private func sendHello(on conn: NWConnection) {
        let panel = announcedPanel
        sendControl([
            "type": "hello",
            "pixelsWide": panel.width,
            "pixelsHigh": panel.height,
            "scale": deviceScale,
            "device": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            "id": Self.installID,
            "sizeMode": screenSizeMode,
            "pv": WireProtocol.version,   // issue #132 — absent on old receivers
        ], on: conn)
        Log.info("hello sent")
    }

    static var storedPrefs: StreamPrefs {
        let defaults = UserDefaults.standard
        let audio = defaults.object(forKey: StreamPrefs.audioDefaultsKey) as? Bool ?? true
        return StreamPrefs.decoded(quality: defaults.string(forKey: StreamQuality.defaultsKey),
                                   audio: audio)
    }

    func sendPrefs(on conn: NWConnection? = nil) {
        let prefs = Self.storedPrefs
        audio.setEnabled(prefs.audio)
        sendControl([
            "type": WireMessage.prefs,
            "quality": prefs.quality.rawValue,
            "audio": prefs.audio,
        ], on: conn)
    }

    /// Touch events: x/y normalized [0,1] in video space, origin top-left.
    /// Stamped in *Mac* clock time (our clock + sync offset) so the Mac can
    /// measure touch→injection latency without doing its own clock sync.
    func sendTouch(phase: String, x: Double, y: Double, mods: Int = 0) {
        var msg: [String: Any] = ["type": "touch", "phase": phase, "x": x, "y": y]
        if mods != 0 { msg["mods"] = mods }
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    /// Two-finger scroll: dx/dy in video pixels (natural-scrolling sign).
    func sendScroll(dx: Double, dy: Double, mods: Int = 0) {
        var msg: [String: Any] = ["type": "scroll", "dx": dx, "dy": dy]
        if mods != 0 { msg["mods"] = mods }
        sendControl(msg)
    }

    func sendKey(phase: String, key: String, mods: Int = 0) {
        guard macSupportsKeyboardWire else { return }
        var msg: [String: Any] = [
            "type": WireMessage.key, "phase": phase, "key": key,
        ]
        if mods != 0 { msg["mods"] = mods }
        sendControl(msg)
    }

    func sendText(_ text: String, mods: Int = 0) {
        guard macSupportsKeyboardWire, !text.isEmpty else { return }
        var msg: [String: Any] = ["type": WireMessage.text, "text": text]
        if mods != 0 { msg["mods"] = mods }
        sendControl(msg)
    }

    func sendMouse(button: String, phase: String, x: Double, y: Double, mods: Int = 0) {
        guard macSupportsKeyboardWire else { return }
        var msg: [String: Any] = [
            "type": WireMessage.mouse, "button": button, "phase": phase, "x": x, "y": y,
        ]
        if mods != 0 { msg["mods"] = mods }
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    /// Apple Pencil stroke/hover. azimuth and altitude are radians.
    func sendPencil(phase: String, x: Double, y: Double,
                    pressure: Double, azimuth: Double, altitude: Double) {
        var msg: [String: Any] = [
            "type": "pencil",
            "phase": phase,
            "x": x, "y": y,
            "pressure": pressure,
            "azimuth": azimuth,
            "altitude": altitude,
            "rotation": 0,
        ]
        if let offset = clockOffsetMs { msg["t"] = nowMs + offset }
        sendControl(msg)
    }

    func sendProximity(entering: Bool, x: Double, y: Double) {
        sendControl(["type": "proximity", "entering": entering, "x": x, "y": y])
    }

    private func sendControl(_ message: [String: Any], on conn: NWConnection? = nil,
                             completion: (() -> Void)? = nil) {
        guard let conn = conn ?? connection,
              let payload = try? JSONSerialization.data(withJSONObject: message) else {
            completion?()
            return
        }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { error in
            if let error { Log.info("control send error: \(error)") }
            completion?()
        })
    }

    // MARK: - Socket read + length-prefixed deframing

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastDataReceived = Date()
                self.bytesThisWindow += data.count
                self.buffer.append(data)
                self.drainFrames()
            }
            if let error {
                Log.info("receive error: \(error)")
                self.queue.async {
                    guard self.connection === conn else { return }
                    self.dropConnection(status: "Connection lost")
                }
                return
            }
            if isComplete {
                Log.info("peer closed connection")
                self.queue.async {
                    guard self.connection === conn else { return }
                    self.dropConnection(status: "The Mac ended the session")
                }
                return
            }
            self.receive(on: conn)
        }
    }

    private func drainFrames() {
        // Cursor-based drain so we only compact the buffer once per batch.
        var cursor = buffer.startIndex
        while buffer.distance(from: cursor, to: buffer.endIndex) >= 4 {
            let len = buffer[cursor..<buffer.index(cursor, offsetBy: 4)]
                .withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.distance(from: cursor, to: buffer.endIndex) >= 4 + len else { break }
            let start = buffer.index(cursor, offsetBy: 4)
            let end = buffer.index(start, offsetBy: len)
            handleAnnexB(Data(buffer[start..<end]))
            cursor = end
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
    }

    // MARK: - Annex B -> CMSampleBuffer

    private func handleAnnexB(_ data: Data) {
        // Pure JSON payload = control message (pong, cursor sprite etc.).
        // Video frames also begin with '{' (telemetry prefix) but always
        // contain start codes — the null bytes make them unambiguous even
        // against multi-KB JSON (cursor sprites are base64, NUL-free).
        if data.count < 32_768, data.first == UInt8(ascii: "{"), !data.contains(0x00) {
            handleVideoChannelJSON(data)
            return
        }

        // Split on 4-byte start codes (our sender only emits 00 00 00 01).
        // Bytes before the FIRST start code are the telemetry prefix
        // ({"cap":…,"snd":…} stamped by the Mac).
        var nalus: [Data] = []
        var metaPrefix: Data?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var naluStart: Int? = nil
            var firstSC: Int? = nil
            var i = 0
            while i + 4 <= bytes.count {
                if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                    if firstSC == nil { firstSC = i }
                    if let s = naluStart, s < i { nalus.append(Data(bytes[s..<i])) }
                    naluStart = i + 4
                    i += 4
                } else {
                    i += 1
                }
            }
            if let s = naluStart, s < bytes.count { nalus.append(Data(bytes[s...])) }
            if let f = firstSC, f > 0 { metaPrefix = Data(bytes[0..<f]) }
        }

        var captureMs: Double?
        var sendMs: Double?
        if let metaPrefix,
           let meta = try? JSONSerialization.jsonObject(with: metaPrefix) as? [String: Any] {
            captureMs = meta["cap"] as? Double
            sendMs = meta["snd"] as? Double
        }

        var vclNALUs: [Data] = []
        for nalu in nalus {
            guard let first = nalu.first else { continue }
            switch first & 0x1F {
            case 7:                                  // SPS (stream may change
                if sps != nalu {                     //  size on rotation)
                    sps = nalu
                    formatDesc = nil
                }
            case 8:                                  // PPS
                if pps != nalu {
                    pps = nalu
                    formatDesc = nil
                }
            case 6: break                            // SEI — skip
            default: vclNALUs.append(nalu)           // slice data
            }
        }
        if formatDesc == nil, let sps, let pps {
            displayLayer.flush()   // drop any frames from the previous format
            buildFormatDescription(sps: sps, pps: pps)
        }
        guard !vclNALUs.isEmpty else { return }
        // All slices of one wire frame go into ONE sample buffer.
        enqueueFrame(vclNALUs, captureMs: captureMs, sendMs: sendMs)
    }

    private func buildFormatDescription(sps: Data, pps: Data) {
        sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let ptrs: [UnsafePointer<UInt8>] = [
                    spsBuf.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBuf.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                if status == noErr, let formatDesc {
                    let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
                    Log.info("format description built: \(dims.width)x\(dims.height)")
                    DispatchQueue.main.async {
                        self.videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
                    }
                    setStatus("Receiving \(dims.width)×\(dims.height)")
                } else {
                    Log.info("format description FAILED: \(status)")
                }
            }
        }
    }

    private func enqueueFrame(_ nalus: [Data], captureMs: Double? = nil, sendMs: Double? = nil) {
        guard let formatDesc else { return }
        // Backgrounded linger: hardware decode is off-limits there, so drop
        // frames at the door instead of feeding a failing display layer at
        // frame rate. setRenderingPaused(false) re-syncs with a keyframe.
        if renderingPaused { return }

        // Build one AVCC buffer: each NALU prefixed with 4-byte big-endian length.
        var avcc = Data(capacity: nalus.reduce(0) { $0 + $1.count + 4 })
        for nalu in nalus {
            var len = UInt32(nalu.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nalu)
        }

        // Allocate a block buffer that OWNS its memory and copy the bytes in —
        // referencing a transient Swift buffer here is a use-after-free.
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,                   // let CoreMedia allocate
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil, offsetToData: 0,
                dataLength: avcc.count, flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return }
        let copyStatus = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copyStatus == noErr else { return }

        var sample: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr,
            sampleBufferOut: &sample)

        guard let sample else { return }

        // Display immediately: low latency, no PTS scheduling.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            Log.info("display layer failed (\(String(describing: displayLayer.error))) — flushing")
            decodeFlushes += 1
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)

        // Per-frame timing for the performance overlay.
        let now = Date()
        if let last = lastFrameAt {
            let ms = now.timeIntervalSince(last) * 1000
            frameIntervals.append(ms)
            if frameIntervals.count > maxSamples { frameIntervals.removeFirst() }
            if ms > 50 { stallsThisWindow += 1 }
        }
        lastFrameAt = now

        // True end-to-end latency: Mac capture timestamp vs our clock mapped
        // onto the Mac's via the ping/pong offset.
        if let captureMs, let sendMs {
            encodeWindow.append(sendMs - captureMs)
            if let offset = clockOffsetMs {
                let e2e = (nowMs + offset) - captureMs
                if e2e > -50, e2e < 5000 {
                    e2eWindow.append(e2e)
                    e2eRing.append(max(e2e, 0))
                    if e2eRing.count > maxSamples { e2eRing.removeFirst() }
                }
            }
        }

        framesThisWindow += 1
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            let fps = Int(Double(framesThisWindow) / elapsed)
            var stats = PerfStats()
            stats.fps = fps
            stats.mbps = Double(bytesThisWindow) * 8 / elapsed / 1_000_000
            stats.samples = frameIntervals
            stats.stalls = stallsThisWindow
            stats.decodeFlushes = decodeFlushes
            stats.e2eP50 = percentile(e2eWindow, 0.5)
            stats.e2eP95 = percentile(e2eWindow, 0.95)
            stats.encodeP50 = percentile(encodeWindow, 0.5)
            stats.rttMs = lastRttMs
            stats.e2eSamples = e2eRing
            stats.transport = transport
            stats.macEncDrops = macEncDrops
            stats.macNetDrops = macNetDrops
            stats.macPending = macPending
            stats.inputP50 = macInputP50
            stats.capFps = macCapFps
            framesThisWindow = 0
            bytesThisWindow = 0
            stallsThisWindow = 0
            fpsWindowStart = now

            // Every 5s, report the aggregate to the Mac so its log holds the
            // full pipeline picture for offline analysis.
            statsReportCounter += 1
            if statsReportCounter >= 5 {
                statsReportCounter = 0
                sendControl([
                    "type": "stats",
                    "transport": transport,
                    "fps": fps,
                    "mbps": (stats.mbps * 10).rounded() / 10,
                    "e2e50": stats.e2eP50.rounded(),
                    "e2e95": stats.e2eP95.rounded(),
                    "enc50": stats.encodeP50.rounded(),
                    "rtt": lastRttMs.rounded(),
                    "stalls": stats.stalls,
                    "inp50": macInputP50.rounded(),
                    "capFps": macCapFps,
                    "offsetKnown": clockOffsetMs != nil,
                ])
                e2eWindow.removeAll(keepingCapacity: true)
                encodeWindow.removeAll(keepingCapacity: true)
            }

            DispatchQueue.main.async {
                self.fps = fps
                self.perf = stats
            }
        }
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    // MARK: - Helpers

    private func setStatus(_ text: String) {
        Log.info("status: \(text)")
        DispatchQueue.main.async { self.status = text }
    }

    private func setConnected(_ value: Bool) {
        DispatchQueue.main.async {
            self.connected = value
            if !value {
                self.macProtocolVersion = WireProtocol.assumedWhenAbsent
                self.onDisconnect?()
            }
        }
        // Remember the first ever successful connection to a Mac so the
        // first-run onboarding hint never reappears (issue #49).
        if value, !UserDefaults.standard.bool(forKey: "hasConnectedBefore") {
            UserDefaults.standard.set(true, forKey: "hasConnectedBefore")
        }
    }

    private func setDialing(_ value: Bool, macName name: String?) {
        DispatchQueue.main.async {
            self.dialing = value
            self.macName = name
        }
    }
}
