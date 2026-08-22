// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 5

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    static let keyboardWireVersion = 4

    static let audioWireVersion = 5

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
    static let key = "key"
    static let text = "text"
    static let mouse = "mouse"
    static let prefs = "prefs"
    static let audioStart = "audioStart"
    static let audio = "audio"
}

struct WireModifiers: OptionSet {
    let rawValue: Int

    static let shift = WireModifiers(rawValue: 1 << 0)
    static let control = WireModifiers(rawValue: 1 << 1)
    static let option = WireModifiers(rawValue: 1 << 2)
    static let command = WireModifiers(rawValue: 1 << 3)
    static let capsLock = WireModifiers(rawValue: 1 << 4)
    static let function = WireModifiers(rawValue: 1 << 5)
}
