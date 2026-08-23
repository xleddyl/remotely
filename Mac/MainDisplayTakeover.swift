import AppKit
import CoreGraphics
import Foundation

enum MainDisplayTakeoverAction: Equatable {
    case engage(CGDirectDisplayID)
    case release
    case unchanged
}

struct MainDisplayTakeoverState: Equatable {
    private(set) var engagedDisplay: CGDirectDisplayID?

    var isEngaged: Bool { engagedDisplay != nil }

    mutating func apply(desiredDisplay: CGDirectDisplayID?) -> MainDisplayTakeoverAction {
        guard let desiredDisplay else {
            guard engagedDisplay != nil else { return .unchanged }
            engagedDisplay = nil
            return .release
        }
        guard desiredDisplay != engagedDisplay else { return .unchanged }
        engagedDisplay = desiredDisplay
        return .engage(desiredDisplay)
    }

    mutating func engageFailed() {
        engagedDisplay = nil
    }
}

struct MainDisplayTakeoverRecord: Equatable {
    struct Placement: Equatable {
        let displayID: CGDirectDisplayID
        let origin: CGPoint
    }

    let previousMainDisplayID: CGDirectDisplayID
    let placements: [Placement]

    var storage: [Int] {
        var record = [Int(previousMainDisplayID)]
        for placement in placements {
            record.append(Int(placement.displayID))
            record.append(Int(placement.origin.x))
            record.append(Int(placement.origin.y))
        }
        return record
    }

    init(previousMainDisplayID: CGDirectDisplayID, placements: [Placement]) {
        self.previousMainDisplayID = previousMainDisplayID
        self.placements = placements
    }

    init?(storage: [Int]?) {
        guard let storage, !storage.isEmpty, (storage.count - 1) % 3 == 0,
              let main = CGDirectDisplayID(exactly: storage[0]) else { return nil }
        var parsed: [Placement] = []
        for index in stride(from: 1, to: storage.count, by: 3) {
            guard let id = CGDirectDisplayID(exactly: storage[index]) else { return nil }
            parsed.append(Placement(displayID: id,
                                    origin: CGPoint(x: storage[index + 1],
                                                    y: storage[index + 2])))
        }
        previousMainDisplayID = main
        placements = parsed
    }
}

@MainActor
final class MainDisplayTakeover {
    static let shared = MainDisplayTakeover()

    private static let markerKey = "mainDisplayTakeover"
    private static let builtInBrightnessKey = "mainDisplayTakeoverBuiltInBrightness"
    private let blanksOwnScreens = UserDefaults.standard.object(forKey: "blankOwnScreens") == nil
        || UserDefaults.standard.bool(forKey: "blankOwnScreens")

    private struct DimmedBuiltIn {
        let displayID: CGDirectDisplayID
        let previousBrightness: Float
    }

    private var state = MainDisplayTakeoverState()
    private var covers: [CGDirectDisplayID: NSWindow] = [:]
    private var keepVisible: Set<CGDirectDisplayID> = []
    private var enforcementTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var dimmedBuiltIn: DimmedBuiltIn?

    func healAfterUncleanExit() {
        restorePersistedBuiltInBrightness()
        guard UserDefaults.standard.array(forKey: Self.markerKey) != nil else { return }
        Log.info("main-display takeover marker found at launch — the last run left the "
            + "desktop rearranged; restoring it")
        restoreArrangement()
    }

    func update(primary: CGDirectDisplayID?, keepVisible: Set<CGDirectDisplayID>) {
        self.keepVisible = keepVisible
        switch state.apply(desiredDisplay: primary) {
        case .unchanged:
            if state.isEngaged { refreshCovers() }
        case .engage(let displayID):
            teardown()
            guard engage(displayID) else {
                state.engageFailed()
                teardown()
                return
            }
        case .release:
            teardown()
        }
    }

    func releaseNow() {
        _ = state.apply(desiredDisplay: nil)
        teardown()
    }

    private func engage(_ displayID: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else {
            Log.info("main-display takeover: display \(displayID) is not on the desktop, skipping")
            return false
        }
        let others = activeDisplays().filter { $0 != displayID }
        guard !others.isEmpty else {
            Log.info("main-display takeover: display \(displayID) is the only display, nothing to take over")
            return false
        }

        let record = MainDisplayTakeoverRecord(
            previousMainDisplayID: CGMainDisplayID(),
            placements: activeDisplays().map {
                .init(displayID: $0, origin: CGDisplayBounds($0).origin)
            })
        UserDefaults.standard.set(record.storage, forKey: Self.markerKey)

        guard shift(by: CGPoint(x: -bounds.origin.x, y: -bounds.origin.y)) else {
            UserDefaults.standard.removeObject(forKey: Self.markerKey)
            return false
        }
        guard CGMainDisplayID() == displayID else {
            Log.info("main-display takeover: display \(displayID) is at the origin but macOS "
                + "still reports \(CGMainDisplayID()) as main — undoing")
            restoreArrangement()
            return false
        }
        Log.info("main-display takeover: display \(displayID) is now the main display")
        refreshCovers()
        observeScreenChanges()
        startEnforcement()
        return true
    }

    private func shift(by delta: CGPoint) -> Bool {
        guard delta != .zero else { return true }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            Log.info("main-display takeover: CGBeginDisplayConfiguration failed")
            return false
        }
        for id in activeDisplays() {
            let origin = CGDisplayBounds(id).origin
            CGConfigureDisplayOrigin(config, id,
                                     Int32(origin.x + delta.x), Int32(origin.y + delta.y))
        }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        guard err == .success else {
            Log.info("main-display takeover: CGCompleteDisplayConfiguration failed (\(err.rawValue))")
            return false
        }
        return true
    }

    private func teardown() {
        stopEnforcement()
        stopObservingScreenChanges()
        removeCovers()
        restoreArrangement()
    }

    private func restoreArrangement() {
        let stored = UserDefaults.standard.array(forKey: Self.markerKey) as? [Int]
        guard stored != nil else { return }
        let record = MainDisplayTakeoverRecord(storage: stored)
        CGRestorePermanentDisplayConfiguration()
        if let record, CGMainDisplayID() != record.previousMainDisplayID {
            let bounds = CGDisplayBounds(record.previousMainDisplayID)
            if !bounds.isEmpty {
                _ = shift(by: CGPoint(x: -bounds.origin.x, y: -bounds.origin.y))
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.markerKey)
        Log.info("main-display takeover released — main display is \(CGMainDisplayID())")
    }

    private func refreshCovers() {
        guard blanksOwnScreens, let primary = state.engagedDisplay else {
            removeCovers()
            return
        }
        var wanted: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, id != primary, !keepVisible.contains(id) else { continue }
            wanted.insert(id)
            let window = covers[id] ?? makeCover()
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            covers[id] = window
        }
        for (id, window) in covers where !wanted.contains(id) {
            window.orderOut(nil)
            covers[id] = nil
        }
        refreshBuiltInDimming(covered: wanted)
    }

    private func refreshBuiltInDimming(covered: Set<CGDirectDisplayID>) {
        guard let builtIn = covered.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            restoreBuiltInBrightness()
            return
        }
        if let dimmed = dimmedBuiltIn, dimmed.displayID != builtIn {
            restoreBuiltInBrightness()
        }
        guard dimmedBuiltIn == nil else {
            if let current = DisplayBacklight.brightness(of: builtIn), current > 0 {
                DisplayBacklight.setBrightness(0, on: builtIn)
            }
            return
        }
        guard let previous = DisplayBacklight.brightness(of: builtIn),
              DisplayBacklight.setBrightness(0, on: builtIn) else { return }
        dimmedBuiltIn = DimmedBuiltIn(displayID: builtIn, previousBrightness: previous)
        UserDefaults.standard.set(previous, forKey: Self.builtInBrightnessKey)
        Log.info("main-display takeover: built-in display \(builtIn) backlight off "
            + "(brightness was \(previous))")
    }

    private func restoreBuiltInBrightness() {
        guard let dimmed = dimmedBuiltIn else { return }
        dimmedBuiltIn = nil
        UserDefaults.standard.removeObject(forKey: Self.builtInBrightnessKey)
        guard DisplayBacklight.setBrightness(dimmed.previousBrightness, on: dimmed.displayID) else {
            Log.info("main-display takeover: could not put the backlight of built-in display "
                + "\(dimmed.displayID) back to \(dimmed.previousBrightness)")
            return
        }
        Log.info("main-display takeover: built-in display \(dimmed.displayID) backlight restored "
            + "to \(dimmed.previousBrightness)")
    }

    private func restorePersistedBuiltInBrightness() {
        guard UserDefaults.standard.object(forKey: Self.builtInBrightnessKey) != nil else { return }
        let previous = UserDefaults.standard.float(forKey: Self.builtInBrightnessKey)
        UserDefaults.standard.removeObject(forKey: Self.builtInBrightnessKey)
        guard let builtIn = activeDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            return
        }
        guard DisplayBacklight.setBrightness(previous, on: builtIn) else { return }
        Log.info("main-display takeover: the last run left the built-in display dark — its "
            + "backlight is back at \(previous)")
    }

    private func makeCover() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        return window
    }

    private func removeCovers() {
        covers.values.forEach { $0.orderOut(nil) }
        covers.removeAll()
        restoreBuiltInBrightness()
    }

    private func startEnforcement() {
        stopEnforcement()
        enforcementTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in self.enforce() }
        }
    }

    private func stopEnforcement() {
        enforcementTimer?.invalidate()
        enforcementTimer = nil
    }

    private func enforce() {
        guard let primary = state.engagedDisplay else { return }
        let bounds = CGDisplayBounds(primary)
        guard !bounds.isEmpty else {
            Log.info("main-display takeover: display \(primary) left the desktop — releasing "
                + "so the Mac's own screens come back")
            releaseNow()
            return
        }
        if bounds.origin != .zero || CGMainDisplayID() != primary {
            Log.info("main-display takeover: display \(primary) drifted to "
                + "(\(Int(bounds.origin.x)),\(Int(bounds.origin.y))) — re-asserting the origin")
            _ = shift(by: CGPoint(x: -bounds.origin.x, y: -bounds.origin.y))
        }
        refreshCovers()
    }

    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in
                Task { @MainActor in self.enforce() }
            }
    }

    private func stopObservingScreenChanges() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
