import AVFoundation
import Foundation

final class AudioPlayer {

    private let queue = DispatchQueue(label: "receiver.audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var converter: AVAudioConverter?
    private var packetFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var signature: String?
    private var attached = false
    private var running = false
    private var suspended = false
    private var enabled = true
    private var sessionActive = false
    private var expectedSequence: Int?
    private var nextStartAttempt = Date.distantPast
    private var lostPackets = 0
    private var droppedForBacklog = 0

    private var reportedFirstSchedule = false
    private var reportedIdlePackets = false
    private var lastEngineErrorAt = Date.distantPast
    private var packetsIn = 0
    private var bytesIn = 0
    private var packetsDecoded = 0
    private var framesScheduled: UInt64 = 0
    private var decodeErrors = 0
    private var emptyDecodes = 0
    private var packetsWithoutEngine = 0
    private var windowStart = Date()
    private let countersInterval: TimeInterval = 5

    private let backlogLock = NSLock()
    private var scheduledFrames: AVAudioFrameCount = 0
    private var maxBacklogFrames: AVAudioFrameCount = 0

    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.rebuildEngine() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Wire events

    func start(sampleRate: Double, channels: Int, cookie: Data?) {
        queue.async { self.configure(sampleRate: sampleRate, channels: channels, cookie: cookie) }
    }

    func play(sequence: Int, base64: String) {
        queue.async { self.decode(sequence: sequence, base64: base64) }
    }

    // MARK: - Lifecycle

    func setEnabled(_ value: Bool) {
        queue.async {
            guard self.enabled != value else { return }
            self.enabled = value
            Log.info("audio: playback \(value ? "enabled" : "disabled") by prefs")
            if !value { self.teardown() }
        }
    }

    func suspend() {
        queue.async {
            guard !self.suspended else { return }
            self.suspended = true
            Log.info("audio: suspended (backgrounded)")
            self.stopEngine()
        }
    }

    func resume() {
        queue.async {
            guard self.suspended else { return }
            self.suspended = false
            self.nextStartAttempt = .distantPast
            guard self.converter != nil else { return }
            Log.info("audio: resuming playback")
            self.converter?.reset()
            self.startEngine()
        }
    }

    func stop() {
        queue.async { self.teardown() }
    }

    // MARK: - Engine

    private func configure(sampleRate: Double, channels: Int, cookie: Data?) {
        Log.info("audio: audioStart \(Int(sampleRate))Hz \(channels)ch cookie \(cookie?.count ?? 0)B "
            + "(enabled=\(enabled) suspended=\(suspended))")
        guard enabled, sampleRate > 0, channels > 0 else { return }
        let fingerprint = "\(sampleRate)/\(channels)/\(cookie?.base64EncodedString() ?? "")"
        if fingerprint == signature, converter != nil {
            converter?.reset()
            resetSequenceTracking()
            if running {
                player.stop()
                flushScheduled()
                player.play()
            }
            return
        }
        teardown()
        let channelCount = AVAudioChannelCount(channels)
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let packets = AVAudioFormat(streamDescription: &description),
              let playback = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                           channels: channelCount),
              let decoder = AVAudioConverter(from: packets, to: playback) else {
            Log.info("audio: could not build a decoder for \(Int(sampleRate))Hz \(channels)ch")
            return
        }
        if let cookie, !cookie.isEmpty {
            decoder.magicCookie = cookie
            Log.info("audio: decoder cookie applied, \(decoder.magicCookie?.count ?? 0)B accepted")
        } else {
            Log.info("audio: no magic cookie on the wire, decoding from the stream description alone")
        }
        converter = decoder
        packetFormat = packets
        playbackFormat = playback
        signature = fingerprint
        maxBacklogFrames = AVAudioFrameCount(sampleRate * 0.25)
        resetSequenceTracking()
        Log.info("audio: decoder ready, AAC-LC -> \(Int(playback.sampleRate))Hz "
            + "\(playback.channelCount)ch \(playback.isInterleaved ? "interleaved" : "deinterleaved"), "
            + "backlog cap \(maxBacklogFrames) frames")
        guard !suspended else { return }
        startEngine()
    }

    private func startEngine() {
        guard enabled, !running, let playback = playbackFormat else { return }
        guard activateSession() else { return }
        if !attached {
            engine.attach(player)
            attached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: playback)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            logEngineFailure("engine would not start (\(error))")
            deactivateSession()
            return
        }
        player.play()
        running = true
        let session = AVAudioSession.sharedInstance()
        Log.info("audio: engine started, output \(Int(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate))Hz, "
            + "session \(Int(session.sampleRate))Hz route "
            + "\(session.currentRoute.outputs.first?.portType.rawValue ?? "none")")
    }

    private func stopEngine() {
        guard running else { return }
        running = false
        player.stop()
        engine.stop()
        flushScheduled()
        deactivateSession()
        Log.info("audio: engine stopped")
    }

    private func rebuildEngine() {
        guard running else { return }
        Log.info("audio: engine configuration changed, rebuilding")
        stopEngine()
        converter?.reset()
        startEngine()
    }

    private func teardown() {
        stopEngine()
        converter = nil
        packetFormat = nil
        playbackFormat = nil
        signature = nil
        nextStartAttempt = .distantPast
        reportedFirstSchedule = false
        reportedIdlePackets = false
        resetSequenceTracking()
    }

    private func activateSession() -> Bool {
        guard !sessionActive else { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            sessionActive = true
            Log.info("audio: session active, category playback")
            return true
        } catch {
            logEngineFailure("session would not activate (\(error))")
            return false
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func logEngineFailure(_ message: String) {
        let now = Date()
        guard now.timeIntervalSince(lastEngineErrorAt) >= countersInterval else { return }
        lastEngineErrorAt = now
        Log.info("audio: \(message)")
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            queue.async {
                Log.info("audio: session interrupted")
                self.stopEngine()
                self.sessionActive = false
            }
        case .ended:
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            guard options.contains(.shouldResume) else { return }
            queue.async {
                guard !self.suspended, self.converter != nil else { return }
                Log.info("audio: interruption ended, restarting the engine")
                self.converter?.reset()
                self.startEngine()
            }
        @unknown default:
            break
        }
    }

    // MARK: - Decode

    private func decode(sequence: Int, base64: String) {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else {
            decodeErrors += 1
            return
        }
        packetsIn += 1
        bytesIn += data.count
        defer { reportCountersIfDue() }
        guard enabled, !suspended, let converter, let packetFormat, let playbackFormat else {
            if !reportedIdlePackets {
                reportedIdlePackets = true
                Log.info("audio: packets arriving with no decoder, waiting for audioStart "
                    + "(enabled=\(enabled) suspended=\(suspended) configured=\(self.converter != nil))")
            }
            return
        }
        if let expected = expectedSequence, sequence != expected {
            lostPackets += 1
            if lostPackets == 1 || lostPackets % 50 == 0 {
                Log.info("audio: packet gap at \(sequence), expected \(expected) (\(lostPackets) so far)")
            }
            converter.reset()
        }
        expectedSequence = sequence + 1
        if !running {
            packetsWithoutEngine += 1
            guard Date() >= nextStartAttempt else { return }
            nextStartAttempt = Date().addingTimeInterval(1)
            startEngine()
        }
        guard running else { return }

        let packet = AVAudioCompressedBuffer(format: packetFormat,
                                             packetCapacity: 1,
                                             maximumPacketSize: data.count)
        packet.byteLength = UInt32(data.count)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count))
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(packet.data, base, data.count)
        }

        let framesPerPacket = AVAudioFrameCount(packetFormat.streamDescription.pointee.mFramesPerPacket)
        guard let decoded = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                             frameCapacity: max(framesPerPacket * 2, 2048)) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: decoded, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return packet
        }
        if status == .error {
            decodeErrors += 1
            if decodeErrors == 1 || decodeErrors % 100 == 0 {
                Log.info("audio: decode failed (\(error?.localizedDescription ?? "unknown")), "
                    + "\(decodeErrors) so far")
            }
            converter.reset()
            return
        }
        guard decoded.frameLength > 0 else {
            emptyDecodes += 1
            return
        }
        packetsDecoded += 1
        schedule(decoded)
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        backlogLock.lock()
        let backlog = scheduledFrames
        if backlog < maxBacklogFrames { scheduledFrames += buffer.frameLength }
        backlogLock.unlock()
        guard backlog < maxBacklogFrames else {
            droppedForBacklog += 1
            if droppedForBacklog % 100 == 1 {
                Log.info("audio: backlog over 250ms, dropping to catch up (\(droppedForBacklog) so far)")
            }
            return
        }
        let frames = buffer.frameLength
        framesScheduled += UInt64(frames)
        if !reportedFirstSchedule {
            reportedFirstSchedule = true
            Log.info("audio: first packet scheduled, \(frames) frames")
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.backlogLock.lock()
            self.scheduledFrames = self.scheduledFrames > frames ? self.scheduledFrames - frames : 0
            self.backlogLock.unlock()
        }
    }

    private func reportCountersIfDue() {
        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= countersInterval else { return }
        windowStart = now
        backlogLock.lock()
        let backlog = scheduledFrames
        backlogLock.unlock()
        Log.info("audio in (\(Int(elapsed))s): \(packetsIn) packets / \(bytesIn)B, "
            + "\(packetsDecoded) decoded / \(framesScheduled) frames scheduled, "
            + "backlog \(backlog) frames, \(droppedForBacklog) backlog drops, "
            + "\(decodeErrors) decode errors, \(emptyDecodes) empty, "
            + "\(packetsWithoutEngine) without an engine, \(lostPackets) gaps, running=\(running)")
        packetsIn = 0
        bytesIn = 0
        packetsDecoded = 0
        framesScheduled = 0
        decodeErrors = 0
        emptyDecodes = 0
        packetsWithoutEngine = 0
    }

    private func flushScheduled() {
        backlogLock.lock()
        scheduledFrames = 0
        backlogLock.unlock()
    }

    private func resetSequenceTracking() {
        expectedSequence = nil
        lostPackets = 0
        droppedForBacklog = 0
    }
}
