import CoreGraphics
import Darwin
import Foundation

enum ScreenSessionState {
    static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static func isLocked(in info: [String: Any]?) -> Bool {
        guard let info else { return false }
        return info[screenIsLockedKey] as? Bool ?? false
    }

    static func isOnConsole(in info: [String: Any]?) -> Bool {
        guard let info else { return true }
        return info[kCGSessionOnConsoleKey as String] as? Bool ?? true
    }

    static func isConsoleInteractive(in info: [String: Any]?) -> Bool {
        isOnConsole(in: info) && !isLocked(in: info)
    }

    static func currentSessionInfo() -> [String: Any]? {
        CGSessionCopyCurrentDictionary() as? [String: Any]
    }

    static var isLocked: Bool { isLocked(in: currentSessionInfo()) }

    static var isOnConsole: Bool { isOnConsole(in: currentSessionInfo()) }

    static var isConsoleInteractive: Bool { isConsoleInteractive(in: currentSessionInfo()) }
}

@MainActor
enum ScreenLocker {
    private typealias LockScreenFn = @convention(c) () -> Int32

    private static let lockScreenImmediate: LockScreenFn? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockScreenFn.self)
    }()

    static func lock() {
        guard !ScreenSessionState.isLocked else { return }
        guard let lockScreenImmediate else {
            Log.info("lock: SACLockScreenImmediate unavailable, leaving the screen unlocked")
            return
        }
        let result = lockScreenImmediate()
        Log.info("lock: locked the screen (result \(result))")
    }
}
