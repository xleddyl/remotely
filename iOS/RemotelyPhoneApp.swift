import SwiftUI
import UIKit

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

/// Project repository — hosts the Mac app download and the setup docs.
let macAppURL = URL(string: "https://github.com/xleddyl/remotely")!

@main
struct RemotelyPhoneApp: App {
    @AppStorage("appTheme") private var appTheme = "system"

    init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migratedTrackpadDefault") {
            if defaults.string(forKey: "touchInputMode") == "direct" {
                defaults.set("pointer", forKey: "touchInputMode")
            }
            defaults.set(true, forKey: "migratedTrackpadDefault")
        }
    }

    var body: some Scene {
        WindowGroup {
            ReceiverScreen()
                .preferredColorScheme(appTheme == "light" ? .light : appTheme == "dark" ? .dark : nil)
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
