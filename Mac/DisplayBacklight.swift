import CoreGraphics
import Darwin
import Foundation

@MainActor
enum DisplayBacklight {
    private typealias GetBrightnessFn =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct Symbols {
        let get: GetBrightnessFn
        let set: SetBrightnessFn
    }

    private static let symbols: Symbols? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            Log.info("backlight: DisplayServices could not be loaded — the Mac's own screens "
                + "stay lit behind their covers")
            return nil
        }
        guard let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else {
            Log.info("backlight: DisplayServices brightness symbols are missing — the Mac's own "
                + "screens stay lit behind their covers")
            return nil
        }
        return Symbols(get: unsafeBitCast(get, to: GetBrightnessFn.self),
                       set: unsafeBitCast(set, to: SetBrightnessFn.self))
    }()

    static var isAvailable: Bool { symbols != nil }

    static func brightness(of id: CGDirectDisplayID) -> Float? {
        guard let symbols else { return nil }
        var value: Float = 0
        let result = symbols.get(id, &value)
        guard result == 0 else {
            Log.info("backlight: reading the brightness of display \(id) failed (\(result))")
            return nil
        }
        return value
    }

    @discardableResult
    static func setBrightness(_ value: Float, on id: CGDirectDisplayID) -> Bool {
        guard let symbols else { return false }
        let result = symbols.set(id, value)
        guard result == 0 else {
            Log.info("backlight: setting the brightness of display \(id) to \(value) "
                + "failed (\(result))")
            return false
        }
        return true
    }
}
