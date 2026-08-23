import AudioToolbox
import CoreAudio
import Foundation

@MainActor
final class OutputMuter {
    static let shared = OutputMuter()

    private enum Silenced {
        case mute(UInt32)
        case volume(Float32)
    }

    private var wanted = false
    private var device: AudioObjectID?
    private var previous: Silenced?
    private var listener: AudioObjectPropertyListenerBlock?

    func engage() {
        guard !wanted else { return }
        wanted = true
        observeDefaultDevice()
        silenceDefaultDevice()
    }

    func release() {
        guard wanted else { return }
        wanted = false
        stopObservingDefaultDevice()
        restoreSilencedDevice()
    }

    private func silenceDefaultDevice() {
        guard let target = defaultOutputDevice() else { return }
        guard let state = silence(target) else { return }
        device = target
        previous = state
        Log.info("output muter: device \(target) silenced while the Mac streams its audio")
    }

    private func restoreSilencedDevice() {
        guard let target = device, let state = previous else { return }
        device = nil
        previous = nil
        restore(state, on: target)
    }

    private func defaultDeviceChanged() {
        guard wanted else { return }
        let current = defaultOutputDevice()
        guard current != device else { return }
        restoreSilencedDevice()
        guard let current else {
            Log.info("output muter: the Mac has no default output device right now")
            return
        }
        Log.info("output muter: the default output moved to device \(current), following it")
        guard let state = silence(current) else { return }
        device = current
        previous = state
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                kAudioObjectPropertyScopeOutput)
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        var address = Self.defaultOutputAddress
        var found = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &found)
        guard status == noErr, found != AudioObjectID(kAudioObjectUnknown) else {
            Log.info("output muter: could not resolve the default output device (\(status))")
            return nil
        }
        return found
    }

    private func silence(_ target: AudioObjectID) -> Silenced? {
        var muteAddress = Self.muteAddress
        if AudioObjectHasProperty(target, &muteAddress) {
            var wasMuted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let read = AudioObjectGetPropertyData(target, &muteAddress, 0, nil, &size, &wasMuted)
            if read == noErr {
                var value: UInt32 = 1
                let written = AudioObjectSetPropertyData(target, &muteAddress, 0, nil,
                                                         UInt32(MemoryLayout<UInt32>.size), &value)
                if written == noErr { return .mute(wasMuted) }
                Log.info("output muter: device \(target) refused the mute (\(written)), "
                    + "falling back to its volume")
            } else {
                Log.info("output muter: device \(target) would not report its mute (\(read)), "
                    + "falling back to its volume")
            }
        }

        var volumeAddress = Self.volumeAddress
        guard AudioObjectHasProperty(target, &volumeAddress) else {
            Log.info("output muter: device \(target) has neither a mute nor a volume control — "
                + "the Mac keeps playing")
            return nil
        }
        var wasVolume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let read = AudioObjectGetPropertyData(target, &volumeAddress, 0, nil, &size, &wasVolume)
        guard read == noErr else {
            Log.info("output muter: device \(target) would not report its volume (\(read)) — "
                + "the Mac keeps playing")
            return nil
        }
        var value: Float32 = 0
        let written = AudioObjectSetPropertyData(target, &volumeAddress, 0, nil,
                                                 UInt32(MemoryLayout<Float32>.size), &value)
        guard written == noErr else {
            Log.info("output muter: device \(target) refused the volume change (\(written)) — "
                + "the Mac keeps playing")
            return nil
        }
        return .volume(wasVolume)
    }

    private func restore(_ state: Silenced, on target: AudioObjectID) {
        switch state {
        case .mute(let wasMuted):
            var address = Self.muteAddress
            var value = wasMuted
            let status = AudioObjectSetPropertyData(target, &address, 0, nil,
                                                    UInt32(MemoryLayout<UInt32>.size), &value)
            guard status == noErr else {
                Log.info("output muter: device \(target) refused the mute restore (\(status))")
                return
            }
            Log.info("output muter: device \(target) mute restored to \(wasMuted)")
        case .volume(let wasVolume):
            var address = Self.volumeAddress
            var value = wasVolume
            let status = AudioObjectSetPropertyData(target, &address, 0, nil,
                                                    UInt32(MemoryLayout<Float32>.size), &value)
            guard status == noErr else {
                Log.info("output muter: device \(target) refused the volume restore (\(status))")
                return
            }
            Log.info("output muter: device \(target) volume restored to \(wasVolume)")
        }
    }

    private func observeDefaultDevice() {
        guard listener == nil else { return }
        var address = Self.defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.defaultDeviceChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                        &address, DispatchQueue.main, block)
        guard status == noErr else {
            Log.info("output muter: could not watch the default output device (\(status)) — "
                + "switching outputs mid-session will not follow")
            return
        }
        listener = block
    }

    private func stopObservingDefaultDevice() {
        guard let block = listener else { return }
        listener = nil
        var address = Self.defaultOutputAddress
        let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                           &address, DispatchQueue.main, block)
        if status != noErr {
            Log.info("output muter: could not stop watching the default output device (\(status))")
        }
    }
}
