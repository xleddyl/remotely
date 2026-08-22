import AVFoundation
import ScreenCaptureKit

@available(macOS 14.0, *)
final class AudioStreamer: NSObject, SCStreamOutput {

    static let sampleRate = 48_000
    static let channelCount = 2
    static let bitRate = 160_000

    let queue = DispatchQueue(label: "sender.audio")

    var send: ((String) -> Void)?

    private let lock = NSLock()
    private var enabledFlag = false
    private var stoppedFlag = false

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFrameCount = 0
    private var sequence: UInt64 = 0
    private var needsStart = true
    private var reportedFailure = false
    private var announcedCookieBytes = -1

    private var describedFirstBuffer = false
    private var reportedFirstPacket = false
    private var reportedLayoutMismatch = false
    private var buffersIn = 0
    private var framesIn: UInt64 = 0
    private var buffersSkipped = 0
    private var buffersUnusable = 0
    private var framesDroppedForBacklog: UInt64 = 0
    private var packetsOut = 0
    private var bytesOut = 0
    private var windowStart = Date()
    private let countersInterval: TimeInterval = 5

    private let maxPendingFrames = AVAudioFrameCount(sampleRate / 4)

    private var enabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledFlag && !stoppedFlag
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedFlag
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        let changed = enabledFlag != value
        enabledFlag = value
        lock.unlock()
        guard changed else { return }
        queue.async {
            Log.info("audio streamer \(value ? "enabled" : "disabled")")
            self.resetEncoder(announcing: value)
        }
    }

    func announceAgain() {
        queue.async {
            Log.info("audio: re-announcing the stream to a fresh peer")
            self.needsStart = true
            self.announcedCookieBytes = -1
            self.pending.removeAll()
            self.pendingFrames = 0
        }
    }

    func stop() {
        lock.lock()
        stoppedFlag = true
        lock.unlock()
        queue.async { self.resetEncoder(announcing: false) }
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        buffersIn += 1
        framesIn += UInt64(CMSampleBufferGetNumSamples(sampleBuffer))
        describeFirstBuffer(sampleBuffer)
        defer { reportCountersIfDue() }
        guard enabled else {
            buffersSkipped += 1
            return
        }
        guard let description = sampleBuffer.formatDescription else {
            buffersUnusable += 1
            return
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = pcmBuffer(from: sampleBuffer, format: format) else {
            buffersUnusable += 1
            return
        }
        guard prepareConverter(for: format) else { return }
        append(buffer)
        drain()
    }

    // MARK: - Encoder

    private func prepareConverter(for format: AVAudioFormat) -> Bool {
        if converter != nil, let sourceFormat, sourceFormat == format { return true }
        resetEncoder(announcing: true)
        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: format.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &description),
              let encoder = AVAudioConverter(from: format, to: output) else {
            reportFailure("could not build the AAC encoder for \(Self.describe(format))")
            return false
        }
        encoder.bitRate = Self.bitRate
        converter = encoder
        sourceFormat = format
        outputFormat = output
        Log.info("audio encoder ready: source \(Self.describe(format)) -> AAC-LC "
            + "\(Self.bitRate / 1000)kbps, bitRate=\(encoder.bitRate), "
            + "maxOutputPacket=\(encoder.maximumOutputPacketSize)B, "
            + "cookie \(encoder.magicCookie?.count ?? 0)B at setup")
        return true
    }

    private func resetEncoder(announcing: Bool) {
        converter = nil
        sourceFormat = nil
        outputFormat = nil
        pending.removeAll()
        pendingFrames = 0
        sequence = 0
        needsStart = announcing
        announcedCookieBytes = -1
        reportedFailure = false
        reportedFirstPacket = false
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        pending.append(buffer)
        pendingFrames += buffer.frameLength
        while pendingFrames > maxPendingFrames, let oldest = pending.first {
            pending.removeFirst()
            pendingFrames -= oldest.frameLength
            framesDroppedForBacklog += UInt64(oldest.frameLength)
        }
    }

    private func drain() {
        guard let converter, let outputFormat else { return }
        while !pending.isEmpty, !stopped {
            let packet = AVAudioCompressedBuffer(
                format: outputFormat,
                packetCapacity: 1,
                maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: packet, error: &error) { _, outStatus in
                guard let next = self.pending.first else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                self.pending.removeFirst()
                self.pendingFrames -= next.frameLength
                outStatus.pointee = .haveData
                return next
            }
            switch status {
            case .haveData:
                emit(packet, cookie: converter.magicCookie)
            case .inputRanDry, .endOfStream:
                emit(packet, cookie: converter.magicCookie)
                return
            case .error:
                reportFailure("AAC encode failed: \(error?.localizedDescription ?? "unknown")")
                return
            @unknown default:
                return
            }
        }
    }

    private func emit(_ packet: AVAudioCompressedBuffer, cookie: Data?) {
        guard let payload = Self.payload(of: packet), let send else { return }
        let cookieBytes = cookie?.count ?? 0
        if needsStart || (announcedCookieBytes == 0 && cookieBytes > 0) {
            let reannounce = !needsStart
            needsStart = false
            announcedCookieBytes = cookieBytes
            let format = packet.format.streamDescription.pointee
            Log.info("audio: \(reannounce ? "re-announcing" : "announcing") audioStart "
                + "\(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch cookie \(cookieBytes)B")
            send("{\"type\":\"\(WireMessage.audioStart)\",\"rate\":\(Int(format.mSampleRate))"
                + ",\"ch\":\(format.mChannelsPerFrame)"
                + ",\"cookie\":\"\(cookie?.base64EncodedString() ?? "")\"}")
        }
        sequence &+= 1
        packetsOut += 1
        bytesOut += payload.count
        if !reportedFirstPacket {
            reportedFirstPacket = true
            Log.info("audio: first AAC packet encoded and sent, \(payload.count)B")
        }
        send("{\"type\":\"\(WireMessage.audio)\",\"seq\":\(sequence),\"d\":\"\(payload.base64EncodedString())\"}")
    }

    private static func payload(of packet: AVAudioCompressedBuffer) -> Data? {
        var offset = 0
        var length = 0
        if packet.packetCount > 0, let description = packet.packetDescriptions?.pointee {
            offset = Int(description.mStartOffset)
            length = Int(description.mDataByteSize)
        }
        if length <= 0 {
            offset = 0
            length = Int(packet.byteLength)
        }
        guard length > 0, offset >= 0, offset + length <= Int(packet.byteCapacity) else { return nil }
        return Data(bytes: packet.data.advanced(by: offset), count: length)
    }

    private func reportFailure(_ message: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        Log.info("\(message): audio stays silent until the capture is rebuilt")
    }

    // MARK: - Instrumentation

    private func describeFirstBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !describedFirstBuffer else { return }
        describedFirstBuffer = true
        guard let description = sampleBuffer.formatDescription,
              let asbd = description.audioStreamBasicDescription else {
            Log.info("audio: first capture buffer has no audio format description")
            return
        }
        Log.info("audio: first capture buffer, \(CMSampleBufferGetNumSamples(sampleBuffer)) frames, "
            + "\(Int(asbd.mSampleRate))Hz \(asbd.mChannelsPerFrame)ch "
            + "flags=0x\(String(asbd.mFormatFlags, radix: 16)) "
            + "bytesPerFrame=\(asbd.mBytesPerFrame) bitsPerChannel=\(asbd.mBitsPerChannel) "
            + "framesPerPacket=\(asbd.mFramesPerPacket)")
    }

    private func reportCountersIfDue() {
        let now = Date()
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= countersInterval else { return }
        windowStart = now
        Log.info("audio out (\(Int(elapsed))s): \(buffersIn) capture buffers / \(framesIn) frames, "
            + "\(packetsOut) packets / \(bytesOut)B sent, "
            + "\(buffersSkipped) skipped (disabled), \(buffersUnusable) unusable, "
            + "\(framesDroppedForBacklog) frames dropped for backlog")
        buffersIn = 0
        framesIn = 0
        buffersSkipped = 0
        buffersUnusable = 0
        framesDroppedForBacklog = 0
        packetsOut = 0
        bytesOut = 0
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz \(format.channelCount)ch "
            + "\(format.isInterleaved ? "interleaved" : "deinterleaved") "
            + "commonFormat=\(format.commonFormat.rawValue)"
    }

    // MARK: - CMSampleBuffer -> AVAudioPCMBuffer

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer,
                           format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        var copied = false
        var sourceBuffers = 0
        try? sampleBuffer.withAudioBufferList { source, _ in
            sourceBuffers = source.count
            guard source.count == destination.count else { return }
            for index in 0..<destination.count {
                guard let from = source[index].mData, let to = destination[index].mData else { return }
                memcpy(to, from, min(Int(source[index].mDataByteSize),
                                     Int(destination[index].mDataByteSize)))
            }
            copied = true
        }
        if !copied, !reportedLayoutMismatch {
            reportedLayoutMismatch = true
            Log.info("audio: capture buffer layout does not match the derived format "
                + "(\(sourceBuffers) source buffers vs \(destination.count) destination), "
                + "dropping audio frames")
        }
        return copied ? copy : nil
    }
}
