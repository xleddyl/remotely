import SwiftUI
import UIKit

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

/// Project repository — hosts the Mac app download and the setup docs.
let macAppURL = URL(string: "https://github.com/xleddyl/remotely")!

@main
struct RemotelyPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiverScreen()
        }
    }
}

// MARK: - Shake to open settings

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
