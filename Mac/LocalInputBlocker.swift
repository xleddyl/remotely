import CoreGraphics
import Foundation

private func localInputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                   userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let blocker = Unmanaged<LocalInputBlocker>.fromOpaque(userInfo).takeUnretainedValue()
    let passes = MainActor.assumeIsolated { blocker.passesThrough(type: type, event: event) }
    return passes ? Unmanaged.passUnretained(event) : nil
}

@MainActor
final class LocalInputBlocker {
    static let shared = LocalInputBlocker()

    private static let escapeKeyCode: Int64 = 53
    private static let escapeHoldToUnlock: CFAbsoluteTime = 3

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                    .mouseMoved, .scrollWheel]
        let systemDefined: CGEventMask = 1 << 14
        return types.reduce(systemDefined) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private var wanted = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var escapeHoldStart: CFAbsoluteTime?
    private var overridden = false

    func engage() {
        guard !wanted else { return }
        wanted = true
        startTap()
    }

    func release() {
        guard wanted else { return }
        wanted = false
        escapeHoldStart = nil
        overridden = false
        stopTap()
    }

    fileprivate func passesThrough(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == InputInjector.injectionTag {
            return true
        }
        if overridden { return true }
        trackEscapeHold(type: type, event: event)
        return overridden
    }

    private func trackEscapeHold(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode else {
                escapeHoldStart = nil
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            guard let started = escapeHoldStart else {
                escapeHoldStart = now
                return
            }
            guard now - started >= Self.escapeHoldToUnlock else { return }
            overridden = true
            Log.info("local input blocker: Esc held on the Mac, its keyboard and mouse "
                + "work again until the device disconnects")
        case .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode else { return }
            escapeHoldStart = nil
        default:
            break
        }
    }

    private func startTap() {
        guard tap == nil else { return }
        guard let created = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: localInputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.info("local input blocker: macOS refused the event tap, Accessibility permission "
                + "is missing, so this Mac's keyboard and mouse stay live")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        runLoopSource = source
        Log.info("local input blocker: this Mac's keyboard and mouse are blocked while a device "
            + "is connected, holding Esc for 3 seconds unlocks them")
    }

    private func stopTap() {
        guard let created = tap else { return }
        tap = nil
        CGEvent.tapEnable(tap: created, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        CFMachPortInvalidate(created)
        Log.info("local input blocker: this Mac's keyboard and mouse are live again")
    }
}
