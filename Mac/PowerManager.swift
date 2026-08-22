import Foundation
import IOKit.pwr_mgt

enum PowerAssertionAction: Equatable {
    case create
    case release
    case unchanged
}

struct PowerAssertionState: Equatable {
    private(set) var held = false

    mutating func apply(activeSessions: Int) -> PowerAssertionAction {
        let wanted = activeSessions > 0
        guard wanted != held else { return .unchanged }
        held = wanted
        return wanted ? .create : .release
    }

    mutating func creationFailed() {
        held = false
    }
}

@MainActor
final class PowerManager {
    static let shared = PowerManager()

    private static let assertionName = "Remotely is streaming to a device"
    private static let activityName = "Remotely session connected"

    private var state = PowerAssertionState()
    private var displaySleepAssertion: IOPMAssertionID?
    private var systemSleepAssertion: IOPMAssertionID?

    func update(activeSessions: Int) {
        switch state.apply(activeSessions: activeSessions) {
        case .unchanged:
            return
        case .create:
            if !hold() {
                state.creationFailed()
                release()
            }
        case .release:
            release()
        }
    }

    func declareUserActivity() {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(Self.activityName as CFString,
                                                      kIOPMUserActiveLocal, &id)
        if result == kIOReturnSuccess {
            Log.info("power: declared local user activity, display waking")
        } else {
            Log.info("power: IOPMAssertionDeclareUserActivity failed (\(result))")
        }
    }

    private func hold() -> Bool {
        guard let display = createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep) else {
            return false
        }
        guard let system = createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep) else {
            IOPMAssertionRelease(display)
            return false
        }
        displaySleepAssertion = display
        systemSleepAssertion = system
        Log.info("power: holding display and system sleep assertions for the live sessions")
        return true
    }

    private func release() {
        let wasHolding = displaySleepAssertion != nil || systemSleepAssertion != nil
        if let display = displaySleepAssertion {
            IOPMAssertionRelease(display)
            displaySleepAssertion = nil
        }
        if let system = systemSleepAssertion {
            IOPMAssertionRelease(system)
            systemSleepAssertion = nil
        }
        guard wasHolding else { return }
        Log.info("power: sleep assertions released, the Mac may idle-sleep again")
    }

    private func createAssertion(_ type: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 Self.assertionName as CFString,
                                                 &id)
        guard result == kIOReturnSuccess else {
            Log.info("power: IOPMAssertionCreateWithName(\(type)) failed (\(result))")
            return nil
        }
        return id
    }
}
