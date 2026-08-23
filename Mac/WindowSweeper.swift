import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class WindowSweeper {
    static let shared = WindowSweeper()

    private static let sweepInterval: TimeInterval = 1
    private static let launchSweepDelay: TimeInterval = 0.5
    private static let minimumWindowSide: CGFloat = 24
    private static let fullScreenAttribute = "AXFullScreen"

    private var wanted = false
    private var target: CGDirectDisplayID?
    private var allowed: Set<CGDirectDisplayID> = []
    private var timer: DispatchSourceTimer?
    private var launchObserver: NSObjectProtocol?
    private var reportedUntrusted = false
    private var reportedFullScreen = false

    func engage(target: CGDirectDisplayID, allowed: Set<CGDirectDisplayID>) {
        self.target = target
        self.allowed = allowed
        guard !wanted else {
            sweep()
            return
        }
        wanted = true
        Log.info("window sweeper: app windows are kept on display \(target) while the Mac's "
            + "own screens are dark")
        startTimer()
        observeLaunches()
        sweep()
    }

    func release() {
        guard wanted else { return }
        wanted = false
        target = nil
        allowed = []
        reportedUntrusted = false
        reportedFullScreen = false
        stopTimer()
        stopObservingLaunches()
        Log.info("window sweeper: windows are free to follow the Mac's own screens again")
    }

    private func startTimer() {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sweep() }
        }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func observeLaunches() {
        guard launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main) { _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.launchSweepDelay * 1_000_000_000))
                    self.sweep()
                }
            }
    }

    private func stopObservingLaunches() {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
    }

    private func sweep() {
        guard wanted, let target else { return }
        let destination = CGDisplayBounds(target)
        guard !destination.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            guard !reportedUntrusted else { return }
            reportedUntrusted = true
            Log.info("window sweeper: Accessibility permission is missing, so windows opened on "
                + "the Mac's own screens stay there")
            return
        }
        let physical = physicalBounds(excluding: target)
        guard !physical.isEmpty else { return }

        var moved = 0
        for pid in strandedOwners(physical: physical) {
            moved += sweepWindows(of: pid, physical: physical, destination: destination)
        }
        guard moved > 0 else { return }
        Log.info("window sweeper: moved \(moved) window(s) onto display \(target)")
    }

    private func physicalBounds(excluding target: CGDirectDisplayID) -> [CGRect] {
        onlineDisplays()
            .filter { $0 != target && !allowed.contains($0) }
            .map(CGDisplayBounds)
            .filter { !$0.isEmpty }
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func strandedOwners(physical: [CGRect]) -> Set<pid_t> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID)
        guard let entries = info as? [[String: Any]] else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        var owners: Set<pid_t> = []
        for entry in entries {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner != own,
                  !owners.contains(owner),
                  let raw = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                  bounds.width >= Self.minimumWindowSide,
                  bounds.height >= Self.minimumWindowSide,
                  display(of: bounds, in: physical) != nil else { continue }
            owners.insert(owner)
        }
        return owners
    }

    private func sweepWindows(of owner: pid_t, physical: [CGRect],
                              destination: CGRect) -> Int {
        let app = AXUIElementCreateApplication(owner)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let windows = value as? [AXUIElement] else { return 0 }
        var moved = 0
        for window in windows
        where reposition(window, physical: physical, destination: destination) {
            moved += 1
        }
        return moved
    }

    private func reposition(_ window: AXUIElement, physical: [CGRect],
                            destination: CGRect) -> Bool {
        guard let origin = point(of: window, attribute: kAXPositionAttribute as String),
              let size = size(of: window), size.width > 0, size.height > 0 else { return false }
        let frame = CGRect(origin: origin, size: size)
        guard let source = display(of: frame, in: physical) else { return false }
        guard !isFullScreen(window) else {
            noteFullScreenLeftBehind()
            return false
        }

        var fitted = size
        fitted.width = min(fitted.width, destination.width)
        fitted.height = min(fitted.height, destination.height)
        if fitted != size, !setSize(fitted, on: window) {
            fitted = size
        }

        let placement = mapped(origin: origin, from: source, to: destination, size: fitted)
        guard abs(placement.x - origin.x) >= 1 || abs(placement.y - origin.y) >= 1 else {
            return false
        }
        return setPoint(placement, attribute: kAXPositionAttribute as String, on: window)
    }

    private func mapped(origin: CGPoint, from source: CGRect, to destination: CGRect,
                        size: CGSize) -> CGPoint {
        let ratioX = source.width > 0 ? (origin.x - source.minX) / source.width : 0
        let ratioY = source.height > 0 ? (origin.y - source.minY) / source.height : 0
        let limitX = max(destination.minX, destination.maxX - size.width)
        let limitY = max(destination.minY, destination.maxY - size.height)
        let x = min(max(destination.minX + ratioX * destination.width, destination.minX), limitX)
        let y = min(max(destination.minY + ratioY * destination.height, destination.minY), limitY)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private func display(of frame: CGRect, in candidates: [CGRect]) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return candidates.first { $0.contains(center) }
    }

    private func noteFullScreenLeftBehind() {
        guard !reportedFullScreen else { return }
        reportedFullScreen = true
        Log.info("window sweeper: a full-screen window cannot be moved, it stays on the Mac's "
            + "own screen until it leaves full screen")
    }

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, Self.fullScreenAttribute as CFString,
                                            &value) == .success,
              let flag = value as? Bool else { return false }
        return flag
    }

    private func point(of element: AXUIElement, attribute: String) -> CGPoint? {
        guard let value = axValue(of: element, attribute: attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func size(of element: AXUIElement) -> CGSize? {
        guard let value = axValue(of: element, attribute: kAXSizeAttribute as String) else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func axValue(of element: AXUIElement, attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func setPoint(_ point: CGPoint, attribute: String, on element: AXUIElement) -> Bool {
        var value = point
        guard let wrapped = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, wrapped) == .success
    }

    private func setSize(_ size: CGSize, on element: AXUIElement) -> Bool {
        var value = size
        guard let wrapped = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString,
                                            wrapped) == .success
    }
}
