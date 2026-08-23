// MacSender — captures a display, H.264-encodes it, streams it to the phone.
//
// Creates a CGVirtualDisplay sized to the phone panel (announced by the phone
// in a "hello" message), hands it the global origin so macOS treats it as the
// primary screen while the Mac's own screens go dark (see
// MainDisplayTakeover), and captures that display.
//
// Pipeline:  ScreenCaptureKit -> VideoToolbox (H.264) -> framed TCP
// Roles: the MAC listens and advertises itself, the DEVICE dials in.
//
// Wire protocol, Mac -> phone:   [4-byte big-endian length][Annex B payload]
//   (keyframes prefixed with SPS+PPS, NALUs delimited by 00 00 00 01)
// Wire protocol, phone -> Mac:   [4-byte big-endian length][JSON message]
//   e.g. {"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3}

import ScreenCaptureKit
import VideoToolbox
import Network
import CoreMedia
import AppKit

struct PhoneInfo: Decodable {
    let pixelsWide: Int   // landscape-oriented (long edge)
    let pixelsHigh: Int
    let scale: Double
    let device: String?   // "iPad" / "iPhone" (older receivers omit it)
    let id: String?       // per-install identity (older receivers omit it) —
                          // the key the controller routes reconnects on
    let pv: Int?          // receiver protocol version (issue #132); absent on
                          // every pre-handshake install → treat as protocol 1

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }

    static let panelPixelRange = 320...20_000
    static let panelScaleRange = 1.0...4.0

    var isUsablePanel: Bool {
        Self.panelPixelRange.contains(pixelsWide)
            && Self.panelPixelRange.contains(pixelsHigh)
            && scale.isFinite
            && Self.panelScaleRange.contains(scale)
    }
}

@available(macOS 14.0, *)
final class MacSender: NSObject, SCStreamOutput, SCStreamDelegate {

    // Status surfaced to the UI (updated on main thread).
    @MainActor var onStatus: ((String) -> Void)?
    @MainActor var onStats: ((Double) -> Void)?   // mbps
    // Fired when a device that dropped stays gone past the reconnect grace:
    // the controller ends the session (capture, virtual display, recording
    // indicator all torn down) instead of holding a display nobody watches.
    @MainActor var onDisconnected: (() -> Void)?
    // Fired when the receiver said goodbye: the device locked, or the app was
    // quit. Either way the user is done, so the controller ends the session
    // right away instead of holding the display for the grace window.
    @MainActor var onPeerGoodbye: (() -> Void)?
    // Fired on every hello. It carries the receiver's install id and panel size
    // so the controller can key the session and show the resolution.
    @MainActor var onHello: ((PhoneInfo) -> Void)?
    @MainActor var onLinkChanged: ((Bool) -> Void)?
    // Fired when the user stopped the capture from the system UI (menu-bar
    // recording indicator / "Stop Extending"). The controller disconnects
    // the session — teardown plus auto-connect opt-out — so the app honors
    // the stop instead of fighting it.
    @MainActor var onCaptureStoppedByUser: (() -> Void)?
    // Fired when the device's display identity had to be abandoned (macOS
    // saved hostile state for it — see setupVirtualDisplay) and a bumped identity
    // came online instead: carries the validated TOTAL offset from the
    // device's base identity, for the controller to store as-is. Absolute,
    // not a delta — repeated bumps in one session must not accumulate into
    // an offset nothing ever validated.
    @MainActor var onDisplayIdentityBumped: ((UInt32) -> Void)?
    @MainActor var onConnected: (() -> Void)?
    // The virtual display that should own the Mac's global origin, or nil
    // once this session no longer has one. The controller stores it on the
    // session and recomputes the takeover from the whole session list — this
    // is a state report, not a command.
    @MainActor var onMainDisplayChanged: ((CGDirectDisplayID?) -> Void)?
    @MainActor var onAudioStreamingChanged: ((Bool) -> Void)?
    @MainActor var onPrefs: ((StreamPrefs) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var audioStreamer: AudioStreamer?
    private var audioRequested = false
    private var audioStreamingReported = false
    private var connection: NWConnection?
    private var virtualDisplay: VirtualDisplay?
    private let queue = DispatchQueue(label: "sender.video")
    private let startCode: [UInt8] = [0, 0, 0, 1]

    private let endpointName: String
    private let quality: StreamQuality
    // Stable per-device serial for the virtual display, so macOS can tell
    // multiple Remotely monitors apart and persist their arrangement.
    private let displaySerial: UInt32
    // How far this device's identity has already moved off its base serial
    // and productID (identities macOS saved hostile state for are abandoned
    // permanently — see setupVirtualDisplay). Advanced in-session when a fallback
    // identity is validated, so a rotation rebuild doesn't re-probe the
    // poisoned one.
    private var baseIdentityOffset: UInt32

    // ── Encoder parallelism limiter (maxPendingEncodes = 1) ─────────────────
    //
    // VTCompressionSessionEncodeFrame returns immediately; the hardware H.264
    // encoder runs asynchronously. If ScreenCaptureKit delivers the next frame
    // before the previous encode callback fires, VideoToolbox will run multiple
    // encodes in parallel inside the same session.
    //
    // Capping pendingEncodes at 1 enforces “latest frame wins” on the encoder:
    // skip captures while an encode is in flight (enc drops), then feed the next
    // fresh buffer when the callback clears the slot. The H.264 reference chain
    // stays valid (pre-encode skip → normal P-frame n→n+2); we do NOT force
    // keyframes on enc drops.
    private var pendingEncodes = 0
    private let maxPendingEncodes = 1

    // ── Outstanding send backpressure (maxPendingSends = 3) ──────────────────
    //
    // pendingSends counts video frames whose NWConnection.send completion has
    // not fired yet — i.e. bytes still in flight / waiting on TCP ACKs. Allow a
    // small pipeline (3) so the link is not idle between ACKs; unlike the encoder,
    // a few outstanding sends helps throughput without piling up seconds of lag.
    //
    // When pendingSends hits the cap we skip the capture before encode (net
    // drops). Same drop point as enc drops, but means “TCP send queue full”, not
    // “encoder busy” — split counters (enc↓ vs net↓) so the HUD shows which
    // bottleneck fired. Never encode-then-discard: dropping here avoids wasting
    // VT work on frames that would only add latency.
    private var pendingSends = 0
    private let maxPendingSends = 3
    private let pipelineLock = NSLock()
    private var dropsEncThisWindow = 0
    private var dropsNetThisWindow = 0
    private var dropsEncTotal = 0
    private var dropsNetTotal = 0
    private var needsKeyframe = true
    private var connectionReady = false
    private var stoppedFlag = false
    private var stopped: Bool {
        get {
            pipelineLock.lock()
            defer { pipelineLock.unlock() }
            return stoppedFlag
        }
        set {
            pipelineLock.lock()
            stoppedFlag = newValue
            pipelineLock.unlock()
        }
    }
    // The liveness monitors are self-rescheduling chains guarded only by
    // `stopped`; arm them at most once per instance so a double start() can't
    // stack parallel loops (the failure mode behind #75). Mirrors the
    // `monitorsStarted` guard the iOS PhoneReceiver already uses.
    private var monitorsStarted = false

    // A dead link ends the session immediately: dropConnection reports the
    // device gone, the virtual display comes down and the windows migrate
    // back to the Mac's screens. A returning device builds a fresh session.
    // This timer only covers sessions born without a connection (restartAll
    // rebuilds): if the device does not redial within this window the
    // watchdog ends them, so they cannot hang around forever.
    private var disconnectedSince: Date?
    private let reconnectGraceSeconds: TimeInterval = 5

    private let idleCaptureStopSeconds: TimeInterval = 15
    private var captureSuspended = false
    private var lastCaptureTarget: (id: CGDirectDisplayID, width: Int, height: Int)?

    private var lastHello: PhoneInfo
    private var inputInjector: InputInjector?

    // Liveness: both sides ping every 2s; if nothing arrives for 5s the link
    // is half-open (the device's app was suspended, the network dropped), so
    // let it go and wait for the device to dial back.
    private var lastReceived = Date()

    // A capture that keeps dying is not coming back on its own (capture
    // authorization revoked, or saved display state blocks the identity) —
    // retrying forever spams WindowServer with create/destroy cycles and,
    // after a user-initiated stop, amounts to defying the user. Counted per
    // failed recovery round, reset by a capture that comes back up. On
    // `queue`.
    private var captureRecoveryFailures = 0
    private let maxCaptureRecoveryFailures = 5

    private var dropsTotal: Int { dropsEncTotal + dropsNetTotal }

    // Local cursor echo: a cursor baked into the video carries the full
    // capture→encode→stream→display latency (~30ms perceived). Instead we
    // hide it from capture and stream its position on the control channel —
    // the phone draws it locally on the ~2ms path the touches use.
    // Escape hatch: `defaults write com.xleddyl.remotely.mac localCursor -bool false`.
    private let localCursor = UserDefaults.standard.object(forKey: "localCursor") == nil
        || UserDefaults.standard.bool(forKey: "localCursor")
    private var cursorTimer: DispatchSourceTimer?
    private var cursorImageTimer: DispatchSourceTimer?
    private var lastCursorSent: (x: Double, y: Double, visible: Bool) = (-1, -1, false)
    private var lastCursorPNGHash = 0
    private var captureDisplayID: CGDirectDisplayID = 0
    // ScreenCaptureKit and VideoToolbox finish work asynchronously. During a
    // rotation, an old capture callback or a late encoder completion must not
    // put a frame from the retired display onto this device's new socket.
    // Bumped on `queue` but read from the SCK sample queue and the VideoToolbox
    // callback queue, so it lives under `pipelineLock` like the other counters
    // those callbacks touch — read it via `captureGenerationNow`.
    private var captureGeneration: UInt64 = 0
    private var captureGenerationNow: UInt64 {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        return captureGeneration
    }

    // Input latency: touches arrive stamped in our clock (the phone applies
    // its sync offset); delta to now = network + deframe + dispatch.
    private var inputLatencies: [Double] = []
    // These policies bound noisy paths while retaining an explicit record when
    // details were suppressed. Unknown types and unparseable messages live on
    // `queue` with the rest of the control-connection state; encoder failures
    // are guarded by `pipelineLock` with the other pipeline counters.
    private var unknownTypeLogPolicy = UnknownControlTypeLogPolicy()
    // Encode failures repeat every frame once the session goes bad; throttle
    // the log to one line a second and carry the count.
    private var encodeFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    // Same for the encoder output callback rejecting a frame; separate policy
    // so "submit failed" and "output rejected" stay distinguishable.
    private var encodeOutputFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    // A framing desync feeds this garbage at the peer's message rate until the
    // watchdog redials, so it needs the same treatment. Detail is the byte
    // count of the last message that would not parse.
    private var unparseableControlLogPolicy = ThrottledLogPolicy<Int>()
    private var textInjectionLogPolicy = ThrottledLogPolicy<Bool>(interval: 2)
    private let maxInjectedTextLength = 512
    private var lastMovedNorm: (x: Double, y: Double)?
    private var lastMovedDelta: (x: Double, y: Double)?
    private var dragReversals = 0
    private var dragSamples = 0
    // Capture cadence: SCK only emits on content change, so the phone can't
    // tell "Mac rendered 45fps" from "frames got lost" — count deliveries here.
    private var capFrames = 0
    private var capWindowStart = Date()

    private var bytesSent = 0
    private var statsWindowStart = Date()

    // ScreenCaptureKit emits frames only when content changes. After a
    // reconnect on a static screen there is nothing to hang the forced
    // keyframe on — so keep the last frame around and re-encode it.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast
    /// Debounced replay after encoder/send backpressure drops a frame.
    /// At most one timer is active; each new drop resets the 30ms deadline.
    private var dropReplayTimer: DispatchSourceTimer?

    init(hello: PhoneInfo, name: String,
         quality: StreamQuality = .best,
         displaySerial: UInt32 = 0x0001,
         identityOffset: UInt32 = 0) {
        self.lastHello = hello
        self.endpointName = name
        self.quality = quality
        self.displaySerial = displaySerial
        self.baseIdentityOffset = identityOffset
        self.disconnectedSince = Date()
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        stopped = false
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
        }

        // Screen Recording permission: poll until granted. No auto-prompt at
        // launch — the permission panel's Grant button triggers the system
        // dialog, so the request always has visible context.
        if !CGPreflightScreenCaptureAccess() {
            await status("Screen Recording permission needed — see Permissions below")
            Log.info("Screen Recording permission missing — waiting for grant via the permission panel")
            while !CGPreflightScreenCaptureAccess() {
                try await Task.sleep(for: .seconds(2))
                if stopped { return }
            }
            Log.info("Screen Recording permission granted")
        }

        try await setupVirtualDisplay(lastHello)

        // Touch back-channel (Milestone 3). Needs Accessibility trust;
        // streaming works without it, so don't interrupt with a prompt —
        // the permission panel's Grant button asks when the user is ready.
        if !AXIsProcessTrusted() {
            await status("Main display — grant Accessibility for touch input")
            // Event posting is trust-checked per-post, so it starts working
            // the moment the user grants — poll just to log/report it.
            while !AXIsProcessTrusted() {
                try await Task.sleep(for: .seconds(2))
                if stopped { return }
            }
            Log.info("Accessibility permission granted — touch input live")
        }
    }

    /// Phone panel is @3x; the virtual display runs @2x HiDPI, so points
    /// = native pixels / 2 (rounded down to even for the encoder).
    private static func points(fromPixels pixels: Int) -> Int { (pixels / 2) & ~1 }

    /// Build (or rebuild) the virtual display + capture for the announced
    /// phone dimensions. Called at startup and again whenever the phone
    /// rotates (it re-sends hello with swapped dimensions).
    private func setupVirtualDisplay(_ info: PhoneInfo) async throws {
        Log.info("phone hello: \(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x")

        let pointsWide = Self.points(fromPixels: info.pixelsWide)
        let pointsHigh = Self.points(fromPixels: info.pixelsHigh)
        // Rough physical size so macOS picks a sane default UI scale.
        let mm = info.pixelsWide >= info.pixelsHigh
            ? CGSize(width: 147, height: 68)
            : CGSize(width: 68, height: 147)

        let displayName = "Remotely — \(endpointName)"
        // Keep one stable identity across rotations. Reconfiguration below
        // applies a new mode to the existing virtual monitor, so macOS keeps
        // its windows and arrangement attached to this physical device.
        let serial = displaySerial
        // Creating a display whose serial is still registered fails — e.g. a
        // just-quit instance's display lingers in WindowServer for a moment
        // after the process dies. Retry through that window instead of
        // parking the session on "Failed" until a manual reconnect.
        //
        // macOS also keys SAVED display state on this identity, and that
        // state can be hostile: the system UI's "Stop Extending" records a
        // config under which the identity never comes online again —
        // creation "succeeds" but the display joins neither the active
        // display list nor shareable content (#206, #221). Unlike the saved
        // mirror-set (#100) and 1x-mode variants, no post-creation
        // enforcement can undo that, so an identity that never surfaces is
        // abandoned for a fresh serial. The controller persists the working
        // offset, so the device skips its poisoned identities from then on.
        var vd: VirtualDisplay?
        var display: SCDisplay?
        var identityError = NSError(domain: "MacSender", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "CGVirtualDisplay creation failed"])
        // Only a created-but-never-surfaced display proves the identity is
        // poisoned. Creation refusing outright usually means a twin still
        // holds the serial (just-quit instance, parallel debug build) —
        // moving to a fallback identity is fine for THIS session, but the
        // move must not be persisted over a merely-transient condition.
        var sawPoisonedIdentity = false
        identities: for probe in 0..<UInt32(3) {
            let totalOffset = baseIdentityOffset &+ probe
            // A lingering serial belongs to a just-quit twin of the CURRENT
            // identity; fresh fallback identities get a shorter window.
            var created: VirtualDisplay?
            for attempt in 0..<(probe == 0 ? 8 : 3) {
                if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
                // A Disconnect during the retry window tore the session down. Bail
                // before creating/assigning the display: the serial the old display
                // held is likely free now, so a late attempt would *succeed* and
                // resurrect the very zombie this retry exists to avoid. (Mirrors the
                // `if stopped` checks in the permission-poll loops above.)
                if stopped { return }
                created = await MainActor.run {
                    // The takeover owns the origin itself (MainDisplayTakeover
                    // puts the display at (0,0)), so there is no per-device
                    // arrangement memory to restore or record here.
                    // The productID moves with the serial: field data in #206
                    // suggests some macOS versions key the hostile state on
                    // the product, not the serial — bumping both escapes
                    // either keying.
                    return VirtualDisplay(name: displayName,
                                          pointsWide: pointsWide, pointsHigh: pointsHigh,
                                          sizeInMillimeters: mm,
                                          serialNum: serial &+ totalOffset,
                                          productID: 0x4F53 &+ totalOffset)
                }
                if created != nil { break }
                Log.info("virtual display creation failed (identity +\(totalOffset), attempt \(attempt + 1)) — retrying")
                await status("Preparing virtual display…")
            }
            guard let candidate = created else { continue }
            virtualDisplay = candidate
            do {
                display = try await findSCDisplay(id: candidate.displayID)
                vd = candidate
                if probe > 0, sawPoisonedIdentity {
                    Log.info("display identity +\(totalOffset) came online — the previous one is "
                        + "poisoned by saved system state; persisting the offset")
                    baseIdentityOffset = totalOffset   // rebuilds skip the dead probe
                    Task { @MainActor in self.onDisplayIdentityBumped?(totalOffset) }
                }
                break identities
            } catch {
                virtualDisplay = nil   // release the dead display and its serial
                // No shareable displays at all is a permission-side failure —
                // a different identity cannot help there.
                if (error as NSError).domain == "MacSender", (error as NSError).code == 4 { throw error }
                identityError = error as NSError
                sawPoisonedIdentity = true
                if stopped { return }
                Log.info("virtual display (identity +\(totalOffset)) never came online — trying a fresh identity")
                await status("Display blocked by saved macOS state — trying a fresh identity…")
            }
        }
        guard let vd, let display else {
            if sawPoisonedIdentity {
                throw NSError(domain: "MacSender", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "saved display state in macOS is blocking "
                        + "Remotely's displays — log out and back in (or restart the Mac), then reconnect"])
            }
            throw identityError
        }
        inputInjector?.releaseHeldButtons()
        inputInjector = InputInjector(displayID: vd.displayID)
        // Quality scaling: capture/encode below native when requested — the
        // display itself stays native so window layout is unaffected.
        let captureW = (Int(Double(pointsWide * 2) * quality.scale)) & ~1
        let captureH = (Int(Double(pointsHigh * 2) * quality.scale)) & ~1
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)
        // Only once the stream is actually up: a session that never captures
        // must not darken the Mac's screens on its way to failing.
        reportMainDisplay(vd.displayID)

        // Debug aid (`defaults write com.xleddyl.remotely.mac testPattern -bool true`):
        // an animated window on the virtual display generates a constant frame
        // stream so steady-state latency can be measured without user activity.
        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
            Task { @MainActor in TestPattern.show(on: id) }
        }
    }

    /// Tear down and rebuild when the phone announces new dimensions. Loops
    /// until the built display matches the latest hello, so rotations that
    /// arrive mid-rebuild aren't lost (and rapid flip-flops settle once).
    private var reconfiguring = false
    private func reconfigure(_ info: PhoneInfo) async {
        guard !reconfiguring, !stopped else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        var target = info
        while !stopped {
            Log.info("reconfiguring for \(target.pixelsWide)x\(target.pixelsHigh)")
            // A cached frame is valid for a network reconnect to the same
            // display, but never for a rotation: it belongs to the retired
            // desktop and can otherwise be replayed onto the new one.
            invalidateCapturePipeline(discardingLastFrame: true)
            let live = stream
            if let live { try? await live.stopCapture() }
            await onQueue {
                if self.stream === live { self.stream = nil }
                self.teardownAudio()
                if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
                self.encoder = nil
            }
            needsKeyframe = true
            do {
                if try await resizeExistingDisplay(for: target) {
                    // The display identity survived, so WindowServer has no
                    // reason to migrate this device's windows to a sibling.
                } else {
                    // Safety fallback for a system that refuses an in-place
                    // mode switch. This keeps the old recovery behaviour.
                    virtualDisplay = nil
                    try await setupVirtualDisplay(target)
                }
            } catch {
                Log.info("reconfigure failed: \(error)")
                await status("Rotation failed: \(error.localizedDescription)")
                queue.async { self.scheduleCaptureRecovery() }
                return
            }
            let latest = lastHello
            if latest.pixelsWide != target.pixelsWide || latest.pixelsHigh != target.pixelsHigh {
                target = latest   // rotated again while we were rebuilding
                continue
            }
            return
        }
    }

    /// Apply the rotated mode to the existing virtual monitor and restart
    /// only the capture/encoder pieces that depend on pixel dimensions.
    /// Returns false when there is no reusable display or macOS rejected the
    /// mode switch, letting the caller use the legacy rebuild fallback.
    private func resizeExistingDisplay(for info: PhoneInfo) async throws -> Bool {
        guard let vd = virtualDisplay else { return false }

        let pointsWide = Self.points(fromPixels: info.pixelsWide)
        let pointsHigh = Self.points(fromPixels: info.pixelsHigh)
        let size = CGSize(width: pointsWide, height: pointsHigh)
        let didResize = await MainActor.run {
            vd.resize(pointsWide: pointsWide, pointsHigh: pointsHigh)
        }
        guard didResize else { return false }

        let display = try await findSCDisplay(id: vd.displayID, expectedSize: size)
        let captureW = (Int(Double(pointsWide * 2) * quality.scale)) & ~1
        let captureH = (Int(Double(pointsHigh * 2) * quality.scale)) & ~1
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)
        inputInjector?.releaseHeldButtons()
        inputInjector = InputInjector(displayID: vd.displayID)
        reportMainDisplay(vd.displayID)

        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
            Task { @MainActor in TestPattern.show(on: id) }
        }
        return true
    }

    /// Tell the controller which display this session wants at the Mac's
    /// global origin (nil = none any more).
    private func reportMainDisplay(_ displayID: CGDirectDisplayID?) {
        Task { @MainActor in self.onMainDisplayChanged?(displayID) }
    }

    /// The virtual display takes a moment to show up in shareable content.
    private func findSCDisplay(id: CGDirectDisplayID, expectedSize: CGSize? = nil) async throws -> SCDisplay {
        var lastDisplayCount = 0
        for _ in 0..<20 {
            let content = try await SCShareableContent.current
            lastDisplayCount = content.displays.count
            if let display = content.displays.first(where: {
                $0.displayID == id
                    && (expectedSize == nil
                        || ($0.width == Int(expectedSize!.width)
                            && $0.height == Int(expectedSize!.height)))
            }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        // An empty display list is a different disease from "ours is
        // missing": capture authorization is broken app-wide, and callers
        // must not burn fallback identities on it.
        if lastDisplayCount == 0 {
            throw NSError(domain: "MacSender", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "macOS returned no capturable displays — "
                              + "the screen may be locked; if this persists unlocked, re-grant "
                              + "Screen Recording in System Settings and relaunch"])
        }
        throw NSError(domain: "MacSender", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "virtual display never appeared in SCShareableContent"])
    }

    private func startCapture(display: SCDisplay, pixelsWide: Int, pixelsHigh: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = pixelsWide
        config.height = pixelsHigh
        // Ask for 120 even though the virtual display is 60Hz: requesting
        // exactly 1/60 makes SCK's rate limiter skip frames that arrive a
        // hair early (beat frequency) — measured ~51fps instead of 60.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        // 420v matches the encoder's native input — skips a BGRA→YUV conversion
        // inside VideoToolbox. (`-pixfmt bgra` reverts for A/B testing.)
        config.pixelFormat = UserDefaults.standard.string(forKey: "pixfmt") == "bgra"
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // One buffer is held permanently (keyframe replay) and one sits in
        // the encoder for ~13ms — headroom prevents SCK starvation drops.
        config.queueDepth = 8
        config.showsCursor = !localCursor
        let peerVersion = lastHello.protocolVersion
        let audioAllowed = peerVersion >= WireProtocol.audioWireVersion
        if audioAllowed {
            config.capturesAudio = true
            config.sampleRate = AudioStreamer.sampleRate
            config.channelCount = AudioStreamer.channelCount
            config.excludesCurrentProcessAudio = true
            Log.info("audio capture requested: \(AudioStreamer.sampleRate)Hz "
                + "\(AudioStreamer.channelCount)ch, peer pv=\(peerVersion), "
                + "device asked for audio=\(audioRequested)")
        } else {
            Log.info("audio capture off: peer pv=\(peerVersion) is below "
                + "\(WireProtocol.audioWireVersion)")
        }

        invalidateCapturePipeline(discardingLastFrame: true)
        await onQueue { self.teardownAudio() }
        let generation = captureGenerationNow
        try setupEncoder(width: pixelsWide, height: pixelsHigh)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        var audio: AudioStreamer?
        if audioAllowed {
            let streamer = makeAudioStreamer()
            do {
                try stream.addStreamOutput(streamer, type: .audio,
                                           sampleHandlerQueue: streamer.queue)
                audio = streamer
                Log.info("audio stream output added")
            } catch {
                Log.info("audio output could not be attached (\(error)), streaming video only")
            }
        }
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            if self.stream === stream { self.stream = nil }
            audio?.stop()
            throw error
        }
        guard !stopped else {
            stream.stopCapture { _ in }
            if self.stream === stream { self.stream = nil }
            audio?.stop()
            await onQueue {
                if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
                self.encoder = nil
            }
            return
        }
        await onQueue {
            self.audioStreamer = audio
            audio?.setEnabled(self.audioRequested)
            if audio != nil {
                Log.info("audio streamer attached to the new capture, enabled=\(self.audioRequested)")
            }
            self.reportAudioStreaming()
        }
        captureDisplayID = display.displayID
        lastCaptureTarget = (display.displayID, pixelsWide, pixelsHigh)
        captureSuspended = false
        lastCursorPNGHash = 0      // rotation rebuilds: re-send the sprite
        lastCursorSent = (-1, -1, false)
        startCursorEcho()
        // A capture that came back through any path (recovery, rotation,
        // identity fallback) earns the full recovery budget again — without
        // this, a pending recovery timer that finds the stream alive exits
        // without ever resetting the counter, and the next unrelated death
        // starts with as little as one round left.
        queue.async { self.captureRecoveryFailures = 0 }
        Log.info("capture started: \(pixelsWide)x\(pixelsHigh) display \(display.displayID) generation \(generation) localCursor=\(localCursor)")
        await status("Main display on \(lastHello.kind) (\(pixelsWide)×\(pixelsHigh))")
    }

    func stop() {
        stopped = true
        virtualDisplay = nil   // releasing it removes the display
        // Belt and braces: the controller already recomputes the takeover from
        // its session list, but a stopped sender never owns the origin again.
        reportMainDisplay(nil)
        Task { @MainActor in self.onAudioStreamingChanged?(false) }
        queue.async {
            self.inputInjector?.releaseHeldButtons()
            self.invalidateCapturePipeline(discardingLastFrame: true)
            self.cursorTimer?.cancel()
            self.cursorTimer = nil
            self.cursorImageTimer?.cancel()
            self.cursorImageTimer = nil
            self.teardownAudio()
            self.stream?.stopCapture { _ in }
            self.stream = nil
            self.connection?.cancel()
            self.connection = nil
            if let encoder = self.encoder { VTCompressionSessionInvalidate(encoder) }
            self.encoder = nil
            self.cancelDropReplayTimer()
        }
    }

    // MARK: - System audio

    private func makeAudioStreamer() -> AudioStreamer {
        let streamer = AudioStreamer()
        streamer.send = { [weak self] json in
            guard let self else { return }
            self.queue.async { self.sendJSONFrame(json) }
        }
        return streamer
    }

    private func teardownAudio() {
        audioStreamer?.stop()
        audioStreamer = nil
        reportAudioStreaming()
    }

    private func setAudioRequested(_ value: Bool) {
        guard audioRequested != value else { return }
        audioRequested = value
        Log.info("device audio \(value ? "on" : "off") (peer pv=\(lastHello.protocolVersion), "
            + "capture \(audioStreamer == nil ? "not carrying audio yet" : "live"))")
        audioStreamer?.setEnabled(value)
        reportAudioStreaming()
    }

    private func reportAudioStreaming() {
        let active = audioStreamer != nil && audioRequested && !stopped
        guard active != audioStreamingReported else { return }
        audioStreamingReported = active
        Task { @MainActor in self.onAudioStreamingChanged?(active) }
    }

    private func onQueue(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                body()
                continuation.resume()
            }
        }
    }

    // The controller's end() is idempotent, but several detectors (grace,
    // refusals, service withdrawal) can conclude "gone" repeatedly while the
    // stop is in flight — report once so the log tells the story once.
    private var goneReported = false

    /// Declare the device gone and end the session (must be called on `queue`).
    private func reportGone(_ reason: String) {
        guard !goneReported, !stopped else { return }
        goneReported = true
        inputInjector?.releaseHeldButtons()
        Log.info(reason)
        Task { @MainActor in self.onDisconnected?() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // A retired stream commonly reports its stop after the replacement is
        // already live. It must not tear down that replacement (#203).
        guard stream === self.stream else { return }
        Log.info("stream stopped with error: \(error)")
        // The user stopped this capture from the system UI (the menu bar's
        // recording indicator / "Stop Extending"). That is a disconnect, not
        // a fault: restarting capture would defy the user — and macOS
        // answers such defiance by saving display state that keeps this
        // identity from ever coming online again (#206). Hand it to the
        // controller to honor exactly like the in-app Disconnect.
        if let scError = error as? SCStreamError, scError.code == .userStopped,
           consoleIsInteractive {
            Task { @MainActor in self.onCaptureStoppedByUser?() }
            return
        }
        Task { await status("Capture stopped: \(error.localizedDescription)") }
        // E.g. display sleep can tear the virtual display down underneath the
        // stream — rebuild instead of sitting dead until an app restart.
        guard !stopped else { return }
        invalidateCapturePipeline()
        queue.async {
            if self.stream === stream { self.stream = nil }
            self.teardownAudio()
            self.scheduleCaptureRecovery()
        }
    }

    /// Retry until capture is back. Per issue #29 fix-plan point 1: a dead
    /// stream does NOT mean the display is gone. If our own virtual display
    /// still exists, just re-attach the capture to it — rebuilding the display
    /// (destroy+create) is what killed the NEIGHBOR's stream and ping-ponged
    /// the infinite rebuild loop. Only do a full `reconfigure` when the display
    /// is actually gone (e.g. display sleep tore it down).
    private func scheduleCaptureRecovery() {
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.stopped, self.stream == nil else { return }
            let hello = self.lastHello
            // Does our virtual display still exist? CGDisplayBounds returns a
            // zero rect for an unknown id, so a non-empty bounds means it's live.
            // Test isEmpty, not isNull: isNull is only true for the special
            // CGRect.null, so it reads as "live" for a dead display too and the
            // rebuild fallback below would become unreachable.
            if let vd = self.virtualDisplay,
               !CGDisplayBounds(vd.displayID).isEmpty {
                guard Self.points(fromPixels: hello.pixelsWide) == vd.pointsWide,
                      Self.points(fromPixels: hello.pixelsHigh) == vd.pointsHigh else {
                    Log.info("capture died at stale geometry, rebuilding for "
                        + "\(hello.pixelsWide)x\(hello.pixelsHigh)")
                    Task {
                        await self.reconfigure(hello)
                        self.queue.async { self.recoveryRoundEnded() }
                    }
                    return
                }
                Log.info("capture died — display still present, re-attaching capture only (#29)")
                Task {
                    do {
                        let display = try await self.findSCDisplay(id: vd.displayID)
                        // Capture at the display's pixel resolution (points ×2 @2x),
                        // not SCDisplay.width (logical points) — matches setupVirtualDisplay.
                        let captureW = (Int(Double(vd.pointsWide * 2) * self.quality.scale)) & ~1
                        let captureH = (Int(Double(vd.pointsHigh * 2) * self.quality.scale)) & ~1
                        try await self.startCapture(display: display,
                                                    pixelsWide: captureW, pixelsHigh: captureH)
                        self.needsKeyframe = true
                    } catch {
                        Log.info("re-attach failed (\(error)) — falling back to full rebuild")
                        await self.reconfigure(hello)
                    }
                    self.queue.async { self.recoveryRoundEnded() }
                }
                return
            }
            // Display genuinely gone — full rebuild (preserves old behavior).
            Log.info("capture died — rebuilding pipeline")
            Task {
                await self.reconfigure(hello)
                self.queue.async { self.recoveryRoundEnded() }
            }
        }
    }

    private func suspendCapture() {
        guard !stopped, let live = stream else { return }
        captureSuspended = true
        invalidateCapturePipeline()
        teardownAudio()
        cursorTimer?.cancel()
        cursorTimer = nil
        cursorImageTimer?.cancel()
        cursorImageTimer = nil
        stream = nil
        live.stopCapture { _ in }
        Log.info("no device for \(Int(idleCaptureStopSeconds))s, capture stopped, display kept")
        Task { await status("Disconnected, waiting for the device to come back") }
    }

    private func resumeCapture() {
        guard !stopped, stream == nil, let target = lastCaptureTarget else {
            captureSuspended = false
            return
        }
        Task {
            do {
                let display = try await self.findSCDisplay(id: target.id)
                try await self.startCapture(display: display,
                                            pixelsWide: target.width, pixelsHigh: target.height)
                self.needsKeyframe = true
            } catch {
                Log.info("capture resume failed (\(error)), handing over to recovery")
                self.queue.async { self.scheduleCaptureRecovery() }
            }
        }
    }

    /// SCK can report `.userStopped` for stops the user did not initiate
    /// when the console goes non-interactive (screen lock, fast user
    /// switch). Only a stop from an interactive console can be a deliberate
    /// menu-bar "stop sharing"; everything else stays on the recovery path,
    /// which was already how those transitions healed before this check
    /// existed.
    private var consoleIsInteractive: Bool {
        ScreenSessionState.isConsoleInteractive
    }

    /// On `queue`: after a recovery round, re-arm the loop while capture is
    /// still down — up to the cap, then declare the session gone. A capture
    /// dead this many rounds is not coming back by itself, and ending the
    /// session (display torn down, reconnect is the user's call) beats
    /// hammering WindowServer with create/destroy cycles forever.
    private func recoveryRoundEnded() {
        guard stream == nil else {
            captureRecoveryFailures = 0
            return
        }
        captureRecoveryFailures += 1
        guard captureRecoveryFailures < maxCaptureRecoveryFailures else {
            Task { await status("Capture could not be restarted") }
            reportGone("capture recovery failed \(captureRecoveryFailures)x — ending session")
            return
        }
        scheduleCaptureRecovery()
    }

    // MARK: - Connection (accepted, never dialed)

    func adopt(_ conn: NWConnection, hello: PhoneInfo) {
        queue.async { [weak self] in
            guard let self, !self.stopped else {
                conn.cancel()
                return
            }
            if let existing = self.connection, existing !== conn {
                Log.info("replacing the connection to \(self.endpointName)")
                existing.cancel()
            }
            self.connection = conn
            self.resetPipelineCounters()
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    guard self.connection === conn, !self.stopped else { return }
                    switch state {
                    case .failed(let error):
                        self.dropConnection("connection failed: \(error)")
                    case .cancelled:
                        self.connectionReady = false
                        self.reportLink(false)
                    default:
                        break
                    }
                }
            }
            self.becomeReady(conn)
            self.applyHello(hello)
        }
    }

    /// Bookkeeping once a connection is live.
    private func becomeReady(_ conn: NWConnection) {
        Log.info("connection ready to \(endpointName)")
        connectionReady = true
        disconnectedSince = nil
        needsKeyframe = true   // new peer needs SPS/PPS + IDR
        // Keep cached pixels: ScreenCaptureKit stays quiet on a static
        // display, and the watchdog needs them to force the reconnect IDR.
        cancelDropReplayTimer()
        // A reconnect can recreate the phone's video view with no cursor
        // sprite; the sprite is otherwise only sent on shape change, so the
        // cursor would stay invisible until the user hovers something that
        // changes it. Reset the dedup state to re-send sprite + position to
        // the fresh peer — the cursor analogue of forcing a keyframe.
        lastCursorPNGHash = 0
        lastCursorSent = (-1, -1, false)
        audioStreamer?.announceAgain()
        lastReceived = Date()  // fresh grace period for the watchdog
        receiveControl(on: conn)
        reportLink(true)
        Task { @MainActor in self.onConnected?() }
        Task { await self.status("Connected to \(self.endpointName)") }
    }

    private func dropConnection(_ reason: String) {
        guard !stopped else { return }
        Log.info("\(endpointName): \(reason)")
        connectionReady = false
        connection?.cancel()
        connection = nil
        resetPipelineCounters()
        inputInjector?.releaseHeldButtons()
        reportLink(false)
        reportGone("link down, ending session")
    }

    private func resetPipelineCounters() {
        pipelineLock.lock()
        pendingEncodes = 0
        pendingSends = 0
        pipelineLock.unlock()
    }

    private func reportLink(_ up: Bool) {
        Task { @MainActor in self.onLinkChanged?(up) }
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady {
                // Liveness + send-side health for the phone's overlay.
                let elapsed = Date().timeIntervalSince(self.capWindowStart)
                let capFps = elapsed > 0 ? Int(Double(self.capFrames) / elapsed) : 0
                self.capFrames = 0
                self.capWindowStart = Date()
                let sorted = self.inputLatencies.sorted()
                let inp50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2].rounded()
                self.sendJSONFrame("{\"type\":\"ping\",\"drops\":\(self.dropsTotal),\"encDrops\":\(self.dropsEncTotal),\"netDrops\":\(self.dropsNetTotal),\"pending\":\(self.pendingSends),\"inp50\":\(inp50),\"capFps\":\(capFps)}")
            }
            self.schedulePing()
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady, Date().timeIntervalSince(self.lastReceived) > 5 {
                // A suspended receiver app (user switched apps, screen off)
                // goes silent like this. Let the half-open socket go; the
                // display and the window arrangement stay up for the grace
                // window so the device resumes into them when it dials back.
                self.dropConnection("nothing from the device for >5s")
            }
            // The grace is only evaluated here, where the clock always ticks:
            // a device that never comes back produces no other event.
            if !self.connectionReady, let since = self.disconnectedSince {
                let away = Date().timeIntervalSince(since)
                if away > self.reconnectGraceSeconds {
                    self.reportGone("device gone for >\(Int(self.reconnectGraceSeconds))s, ending session")
                } else if away > self.idleCaptureStopSeconds {
                    self.suspendCapture()
                }
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            if self.connectionReady, self.needsKeyframe,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
                let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen after reconnect to \(self.endpointName) — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
                            generation: self.captureGenerationNow)
            }
            self.scheduleWatchdog()
        }
    }

    // MARK: - Local cursor echo (Mac -> phone)

    private func startCursorEcho() {
        guard localCursor else { return }
        cursorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))   // 120Hz
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.pollCursorPosition()
        }
        timer.resume()
        cursorTimer = timer
        scheduleCursorImagePoll()
    }

    /// Sprite changes (arrow ↔ I-beam ↔ resize…) must land fast or the wrong
    /// cursor shows over hot areas — poll at 30Hz on the main thread (NSCursor
    /// is AppKit), hash the raw bitmap, and only PNG-encode + send on change.
    ///
    /// A dedicated timer (cancelled+replaced here, like cursorTimer above) — not
    /// a self-rescheduling asyncAfter chain. Every rebuild re-enters
    /// startCursorEcho, and sleep/wake rebuilds happen often; a recursive chain
    /// guarded only by `stopped` would stack one extra 30Hz main-thread
    /// TIFF-encode loop per rebuild, creeping CPU to ~50% until a restart (#75).
    private func scheduleCursorImagePoll() {
        cursorImageTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.033, repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.localCursor else { return }
            self.pollCursorImage()
        }
        timer.resume()
        cursorImageTimer = timer
    }

    private func pollCursorPosition() {
        guard connectionReady, captureDisplayID != 0,
              let loc = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(captureDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.contains(loc) {
            let x = (loc.x - bounds.minX) / bounds.width
            let y = (loc.y - bounds.minY) / bounds.height
            if !lastCursorSent.visible
                || abs(x - lastCursorSent.x) > 0.0004 || abs(y - lastCursorSent.y) > 0.0004 {
                lastCursorSent = (x, y, true)
                sendJSONFrame(String(format: "{\"type\":\"cursor\",\"x\":%.4f,\"y\":%.4f,\"v\":1}", x, y))
            }
        } else if lastCursorSent.visible {
            lastCursorSent.visible = false
            sendJSONFrame("{\"type\":\"cursor\",\"v\":0}")
        }
    }

    private func pollCursorImage() {
        // Display size read LIVE, not snapshotted at capture start: the
        // HiDPI mode settles (and macOS re-flips it) asynchronously, and a
        // sprite normalized against the 1x size renders at half size on the
        // device. Mixing the size into the dedup hash re-sends the sprite
        // whenever the mode flips, so the proportion always heals.
        guard connectionReady, captureDisplayID != 0,
              let cursor = NSCursor.currentSystem else { return }
        let displaySize = CGDisplayBounds(captureDisplayID).size   // points, current mode
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let hash = tiff.hashValue ^ Int(displaySize.width) &* 31
        guard hash != lastCursorPNGHash else { return }
        guard let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count < 24_000 else { return }
        lastCursorPNGHash = hash
        let size = image.size            // Mac points
        let hot = cursor.hotSpot
        // Normalized against the display so the phone can size/anchor the
        // sprite without knowing capture scale or HiDPI factor.
        let msg = String(format:
            "{\"type\":\"cursorImg\",\"nw\":%.5f,\"nh\":%.5f,\"ax\":%.3f,\"ay\":%.3f,\"png\":\"%@\"}",
            size.width / displaySize.width,
            size.height / displaySize.height,
            size.width > 0 ? hot.x / size.width : 0,
            size.height > 0 ? hot.y / size.height : 0,
            png.base64EncodedString())
        queue.async { self.sendJSONFrame(msg) }
    }

    // MARK: - Control messages (phone -> Mac)

    private func receiveControl(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 4 else {
                self.dropConnection(conn, "peer closed")
                return
            }
            let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 1 << 20 else {
                self.dropConnection(conn, "framing error")
                return
            }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] payload, _, _, error in
                guard let self else { return }
                guard error == nil, let payload, payload.count == len else {
                    self.dropConnection(conn, "peer closed")
                    return
                }
                self.queue.async {
                    guard self.connection === conn, !self.stopped else { return }
                    self.handleControl(payload)
                    self.receiveControl(on: conn)
                }
            }
        }
    }

    private func dropConnection(_ conn: NWConnection, _ reason: String) {
        queue.async {
            guard self.connection === conn else { return }
            self.dropConnection(reason)
        }
    }

    private func wireModifiers(_ obj: [String: Any]) -> Int {
        guard let mods = obj["mods"] as? Double else { return 0 }
        return Int(exactly: mods.rounded()) ?? 0
    }

    private func finite(_ obj: [String: Any], _ key: String) -> Double? {
        guard let value = obj[key] as? Double, value.isFinite else { return nil }
        return value
    }

    private func recordPointerSample(phase: String, x: Double, y: Double) {
        guard phase == "moved" else {
            lastMovedNorm = nil
            lastMovedDelta = nil
            return
        }
        defer { lastMovedNorm = (x, y) }
        guard let previous = lastMovedNorm else { return }
        let delta = (x: x - previous.x, y: y - previous.y)
        guard hypot(delta.x, delta.y) > 0.0005 else { return }
        defer { lastMovedDelta = delta }
        guard let last = lastMovedDelta else { return }
        dragSamples += 1
        if delta.x * last.x + delta.y * last.y < 0 { dragReversals += 1 }
    }

    private func recordInputLatency(_ obj: [String: Any]) {
        guard let t = obj["t"] as? Double else { return }
        let delta = Date().timeIntervalSince1970 * 1000 - t
        guard delta > -50, delta < 1000 else { return }
        inputLatencies.append(max(delta, 0))
        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
    }

    private func handleControl(_ payload: Data) {
        lastReceived = Date()
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else {
            handleUnparseableControlLogAction(
                unparseableControlLogPolicy.record(
                    payload.count,
                    at: ProcessInfo.processInfo.systemUptime
                )
            )
            return
        }
        switch type {
        case "ping":
            // Echo with our clock so the phone can estimate the offset
            // (NTP-style) and compute true end-to-end frame latency.
            if let t = obj["t"] as? Double {
                let mt = Date().timeIntervalSince1970 * 1000
                sendJSONFrame("{\"type\":\"pong\",\"t\":\(t),\"mt\":\(mt)}")
            }
        case "stats":
            // Aggregated pipeline health measured on the phone — logged here
            // so one file holds both ends of the story.
            if let json = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: json, encoding: .utf8) {
                Log.info("PHONE-STATS \(line) | mac enc↓=\(dropsEncThisWindow) net↓=\(dropsNetThisWindow) pending=\(pendingSends) pointerReversals=\(dragReversals)/\(dragSamples)")
                dropsEncThisWindow = 0
                dropsNetThisWindow = 0
                dragReversals = 0
                dragSamples = 0
            }
        case "hello":
            if let info = try? JSONDecoder().decode(PhoneInfo.self, from: payload) {
                guard info.isUsablePanel else {
                    Log.info("ignoring an out-of-range hello: "
                        + "\(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x")
                    return
                }
                applyHello(info)
            }
        case "touch":
            if let phase = obj["phase"] as? String,
               let x = finite(obj, "x"),
               let y = finite(obj, "y") {
                recordPointerSample(phase: phase, x: x, y: y)
                inputInjector?.handleTouch(phase: phase, x: x, y: y,
                                           mods: wireModifiers(obj))
                recordInputLatency(obj)
            }
        case "scroll":
            if let dx = finite(obj, "dx"), let dy = finite(obj, "dy") {
                inputInjector?.handleScroll(dx: dx, dy: dy,
                                            mods: wireModifiers(obj))
            }
        case "pencil":
            if let phase = obj["phase"] as? String,
               let x = finite(obj, "x"),
               let y = finite(obj, "y") {
                inputInjector?.handlePencil(
                    phase: phase, x: x, y: y,
                    pressure: finite(obj, "pressure") ?? 0,
                    azimuth: finite(obj, "azimuth") ?? 0,
                    altitude: finite(obj, "altitude") ?? (.pi / 2),
                    rotation: finite(obj, "rotation") ?? 0)
                recordInputLatency(obj)
            }
        case "proximity":
            if let entering = obj["entering"] as? Bool,
               let x = finite(obj, "x"),
               let y = finite(obj, "y") {
                inputInjector?.handleProximity(entering: entering, x: x, y: y)
            }
        case "kf":
            // The phone's decoder lost sync (e.g. it attached mid-GOP and
            // periodic keyframes are off) — force an IDR on the next frame.
            Log.info("phone requested keyframe")
            needsKeyframe = true
        case WireMessage.sleeping:
            // The device locked: nobody can see this display, and the cursor
            // must not be stranded on it. A deliberate goodbye, so the session
            // ends now instead of holding the grace window open.
            Log.info("receiver went to sleep, ending session")
            Task { @MainActor in self.onPeerGoodbye?() }
        case WireMessage.closing:
            // The app on the device is quitting for real.
            Log.info("receiver app closed — ending session")
            Task { @MainActor in self.onPeerGoodbye?() }
        case WireMessage.key:
            if let phase = obj["phase"] as? String,
               let key = obj["key"] as? String {
                inputInjector?.handleKey(phase: phase, key: key,
                                         mods: wireModifiers(obj))
            }
        case WireMessage.text:
            if let text = obj["text"] as? String {
                let injector = inputInjector
                injector?.handleText(String(text.prefix(maxInjectedTextLength)),
                                     mods: wireModifiers(obj))
                handleTextInjectionLogAction(
                    textInjectionLogPolicy.record(
                        injector != nil,
                        at: ProcessInfo.processInfo.systemUptime
                    )
                )
            }
        case WireMessage.prefs:
            let prefs = StreamPrefs.decoded(quality: obj["quality"] as? String,
                                            audio: obj["audio"] as? Bool)
            Log.info("device prefs: quality=\(prefs.quality.rawValue) audio=\(prefs.audio)")
            setAudioRequested(prefs.audio)
            Task { @MainActor in self.onPrefs?(prefs) }
        case WireMessage.mouse:
            if let button = obj["button"] as? String,
               let phase = obj["phase"] as? String,
               let x = finite(obj, "x"),
               let y = finite(obj, "y") {
                inputInjector?.handleMouse(button: button, phase: phase, x: x, y: y,
                                           mods: wireModifiers(obj))
                recordInputLatency(obj)
            }
        default:
            // Unknown types are a normal consequence of the additive wire
            // protocol: a newer peer can send messages this build predates.
            // Log each type once per session, never per message. A peer can
            // drive this at input rates (a pencil stroke is ~240 messages/sec),
            // so the policy also caps distinct types and reports that cap once.
            switch unknownTypeLogPolicy.record(type) {
            case .logType(let type):
                Log.info("unknown control message type: \(type) — ignoring (logged once)")
            case .logSuppression(let limit):
                Log.info("additional unknown control message types suppressed after \(limit) distinct types")
            case .none:
                break
            }
        }
    }

    private func applyHello(_ info: PhoneInfo) {
        let previous = lastHello
        lastHello = info
        Task { @MainActor in self.onHello?(info) }
        // Version handshake (issue #132). Reply with our identity.
        // Additive: older receivers ignore unknown message types.
        sendWelcome()
        if info.protocolVersion < WireProtocol.minSupportedPeer {
            Log.info("receiver protocol \(info.protocolVersion) below supported \(WireProtocol.minSupportedPeer)")
        }
        let rotated = previous.pixelsWide != info.pixelsWide
            || previous.pixelsHigh != info.pixelsHigh
        if captureSuspended {
            if rotated {
                Task { await self.reconfigure(info) }
            } else {
                resumeCapture()
            }
            return
        }
        guard stream != nil, rotated else { return }
        // The device rotated (possibly while it was away), so rebuild after a
        // short debounce so a flurry of orientation flips settles into one.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard self.lastHello.pixelsWide == info.pixelsWide,
                  self.lastHello.pixelsHigh == info.pixelsHigh else { return }
            await self.reconfigure(info)
        }
    }

    // MARK: - Encoder setup

    /// Create the compression session into `encoder`, optionally requiring an
    /// encoder that supports low-latency rate control.
    private func createCompressionSession(width: Int, height: Int, lowLatency: Bool) -> OSStatus {
        let spec: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        return VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
    }

    private func setupEncoder(width: Int, height: Int) throws {
        // Low-latency rate control: the hardware encoder emits every frame
        // immediately instead of pipelining. (`-lowlatency NO` for A/B.)
        let lowLatency = UserDefaults.standard.object(forKey: "lowlatency") == nil
            || UserDefaults.standard.bool(forKey: "lowlatency")
        // The spec filters which encoder VideoToolbox is allowed to pick, so an
        // unsupported key fails creation outright rather than being ignored the
        // way the properties below are: this key *requires* an encoder that
        // offers the mode, and Macs whose only encoder is AMD have none (#133).
        // Retrying without it is close to free — the guarantees the mode makes
        // (infinite GOP, no reordering, High profile) are all set explicitly
        // below, and the default rate controller only pipelines when it is fed
        // faster than real time, which the pendingEncodes backpressure already
        // prevents. Measured on Apple silicon at a paced 60fps: 5.3ms mean
        // submit→emit without the spec vs 6.1ms with it, 1 frame held either
        // way. (Overfeeding it at ~320fps does queue ~8 frames, hence the cap.)
        var status = createCompressionSession(width: width, height: height, lowLatency: lowLatency)
        var usedFallback = false
        if encoder == nil, lowLatency {
            Log.info("VTCompressionSessionCreate failed with low-latency rate control (status \(status)) — retrying without an encoder specification")
            status = createCompressionSession(width: width, height: height, lowLatency: false)
            usedFallback = true
        }
        guard let encoder else {
            // Returning here used to leave the session "connected, all green"
            // with a dead encoder and a black receiver. Throw so the failure
            // reaches the UI as a red "Failed:" status.
            Log.info("FATAL: VTCompressionSessionCreate failed (status \(status))")
            throw NSError(domain: "MacSender", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "This Mac's video encoder could not be started (VideoToolbox error \(status))"
            ])
        }
        // Low-latency settings: real-time, no B-frames, periodic keyframes.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
        // TCP never loses data, and we force a keyframe on reconnect/drop.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: quality.bitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        Log.info("encoder ready: \(width)x\(height) H.264 \(quality.bitrate / 1_000_000)Mbps quality=\(quality.rawValue) lowLatencyRC=\(lowLatency && !usedFallback)\(usedFallback ? " (fallback)" : "")")
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard stream === self.stream,
              type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let generation = captureGenerationNow

        lastPixelBuffer = pixelBuffer
        lastCaptureAt = Date()
        capFrames += 1

        // No receiver, or a pipeline stage is backed up: skip this frame.
        guard connectionReady else { return }
        if shouldDropFrame(reason: "pending_encode") { return }  // encoder busy
        if shouldDropFrame(reason: "pending_sends") { return }   // TCP send queue full

        encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), generation: generation)
    }

    private func isPipelineBackedUp() -> Bool {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        return pendingEncodes >= maxPendingEncodes || pendingSends >= maxPendingSends
    }

    /// Schedule (or reset) a one-shot replay of `lastPixelBuffer` after drops.
    private func scheduleDropReplayTimer() {
        dropReplayTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.dropReplayTimer = nil
            self.replayLastFrameAfterDrop()
        }
        timer.resume()
        dropReplayTimer = timer
    }

    private func cancelDropReplayTimer() {
        dropReplayTimer?.cancel()
        dropReplayTimer = nil
    }

    /// Re-encode the most recent pixel buffer once backpressure clears.
    private func replayLastFrameAfterDrop() {
        guard !stopped, connectionReady, let pixelBuffer = lastPixelBuffer else { return }
        if isPipelineBackedUp() {
            scheduleDropReplayTimer()
            return
        }
        encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
               generation: captureGenerationNow)
    }

    /// Drop when encode or send pipeline is busy.
    /// Pre-encode drops are invisible to the decoder — the H.264 reference
    /// chain stays intact, so the next frame can be a normal P-frame (n → n+2).
    /// Do NOT force keyframes here; that causes IDR pulsing / blockiness.
    private func shouldDropFrame(reason: String) -> Bool {
        pipelineLock.lock()
        let drop: Bool
        switch reason {
        case "pending_encode":
            drop = pendingEncodes >= maxPendingEncodes
        case "pending_sends":
            drop = pendingSends >= maxPendingSends
        default:
            drop = false
        }
        pipelineLock.unlock()
        guard drop else { return false }
        scheduleDropReplayTimer()
        switch reason {
        case "pending_encode":
            dropsEncThisWindow += 1
            dropsEncTotal += 1
        case "pending_sends":
            dropsNetThisWindow += 1
            dropsNetTotal += 1
        default:
            break
        }
        return true
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, generation: UInt64) {
        guard generation == captureGenerationNow, let encoder else { return }
        pipelineLock.lock()
        pendingEncodes += 1
        pipelineLock.unlock()
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var frameProperties: CFDictionary?
        if needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
        }
        let submitStatus = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard let self else { return }
            defer {
                self.pipelineLock.lock()
                self.pendingEncodes = max(0, self.pendingEncodes - 1)
                self.pipelineLock.unlock()
            }
            guard status == noErr, let buffer else {
                // A session rejecting every frame looks healthy in all other
                // counters — the receiver just stays black. Don't be silent.
                self.pipelineLock.lock()
                let logAction = self.encodeOutputFailureLogPolicy.record(
                    status,
                    at: ProcessInfo.processInfo.systemUptime
                )
                self.pipelineLock.unlock()
                self.handleEncodeOutputFailureLogAction(logAction)
                return
            }
            guard generation == self.captureGenerationNow else { return }
            if let data = self.annexB(from: buffer) {
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.sendFramed(framed)
            }
        }
        if submitStatus == noErr {
            // Encode submission commits this frame to the pipeline; stale in-flight
            // encodes started before a drop won't reach here again, so cancel replay.
            cancelDropReplayTimer()
        } else {
            pipelineLock.lock()
            pendingEncodes = max(0, pendingEncodes - 1)
            // A dead encoder session keeps failing, and this runs per frame, so
            // an unthrottled line here is ~60/sec for as long as the problem
            // lasts. Report at most once a second and carry the count: the
            // status code is the diagnosis, the rate is just a number.
            let logAction = encodeFailureLogPolicy.record(
                submitStatus,
                at: ProcessInfo.processInfo.systemUptime
            )
            pipelineLock.unlock()
            handleEncodeFailureLogAction(logAction)
        }
    }

    private func handleEncodeFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeFailureLog() {
        pipelineLock.lock()
        let report = encodeFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeFailures(report) }
    }

    private func reportEncodeFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        Log.info("VTCompressionSessionEncodeFrame failed: \(report.detail) (\(report.count) since last report)")
    }

    private func handleEncodeOutputFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeOutputFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeOutputFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeOutputFailureLog() {
        pipelineLock.lock()
        let report = encodeOutputFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeOutputFailures(report) }
    }

    private func reportEncodeOutputFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        // VideoToolbox can reject a frame with noErr + a nil buffer (e.g.
        // above the H.264 level pixel-rate ceiling) — call that case out.
        let cause = report.detail == noErr ? "nil buffer despite noErr" : "status \(report.detail)"
        Log.info("encoder output rejected: \(cause) (\(report.count) since last report)")
    }

    // Runs on `queue`, where the policy and the control connection both live.
    private func handleUnparseableControlLogAction(_ action: ThrottledLogPolicy<Int>.Action) {
        switch action {
        case .report(let report):
            reportUnparseableControl(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushUnparseableControlLog()
            }
        case .none:
            break
        }
    }

    private func flushUnparseableControlLog() {
        if let report = unparseableControlLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime) {
            reportUnparseableControl(report)
        }
    }

    private func reportUnparseableControl(_ report: ThrottledLogPolicy<Int>.Report) {
        Log.info("unparseable control message (\(report.detail) bytes, \(report.count) since last report)")
    }

    private func handleTextInjectionLogAction(_ action: ThrottledLogPolicy<Bool>.Action) {
        switch action {
        case .report(let report):
            reportTextInjection(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushTextInjectionLog()
            }
        case .none:
            break
        }
    }

    private func flushTextInjectionLog() {
        if let report = textInjectionLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime) {
            reportTextInjection(report)
        }
    }

    private func reportTextInjection(_ report: ThrottledLogPolicy<Bool>.Report) {
        let fate = report.detail ? "injected" : "dropped, no injector"
        Log.info("text wire messages: \(report.count) since last report (\(fate); content never logged)")
    }

    // MARK: - H.264 -> Annex B

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend SPS/PPS (they live in the format description).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {           // index 0 = SPS, 1 = PPS
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let psPtr {
                    out.append(contentsOf: startCode)
                    out.append(Data(bytes: psPtr, count: psLen))
                }
            }
        }
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex B start codes.
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - Version handshake (issue #132)

    /// Identify ourselves to the receiver: our protocol version and the oldest
    /// receiver version we still support.
    private func sendWelcome() {
        sendJSONFrame("{\"type\":\"\(WireMessage.welcome)\",\"pv\":\(WireProtocol.version),\"min\":\(WireProtocol.minSupportedPeer)}")
    }

    // MARK: - Wire framing: [4-byte big-endian length][payload]

    /// Control messages on the video channel (pong etc.) — framed JSON without
    /// start codes; the receiver routes payloads starting with '{'.
    private func sendJSONFrame(_ json: String) {
        guard let connection, connectionReady else { return }
        connection.send(content: lengthPrefixed(Data(json.utf8)),
                        completion: .contentProcessed { _ in })
    }

    private func lengthPrefixed(_ payload: Data) -> Data {
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        return frame
    }

    private func sendFramed(_ payload: Data) {
        guard let connection, connectionReady else { return }
        let frame = lengthPrefixed(payload)
        pipelineLock.lock()
        pendingSends += 1
        pipelineLock.unlock()
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pipelineLock.lock()
            self.pendingSends = max(0, self.pendingSends - 1)
            self.pipelineLock.unlock()
            if let error {
                Log.info("send error: \(error)")
                return
            }
            self.bytesSent += frame.count
            // Report stats roughly once a second.
            let elapsed = Date().timeIntervalSince(self.statsWindowStart)
            if elapsed >= 1.0 {
                let mbps = Double(self.bytesSent) * 8 / elapsed / 1_000_000
                self.bytesSent = 0
                self.statsWindowStart = Date()
                Task { @MainActor in self.onStats?(mbps) }
            }
        })
    }

    // MARK: - Helpers

    private func status(_ text: String) async {
        await MainActor.run { onStatus?(text) }
    }

    /// Invalidate the retired ScreenCaptureKit/VideoToolbox callbacks before
    /// changing the display or encoder they feed.
    private func invalidateCapturePipeline(discardingLastFrame: Bool = false) {
        pipelineLock.lock()
        captureGeneration &+= 1
        pipelineLock.unlock()
        captureDisplayID = 0
        if discardingLastFrame {
            lastPixelBuffer = nil
            lastCaptureAt = .distantPast
        }
    }
}
