import CoreGraphics
import Foundation

/// One connected (or reconnecting) device: its sender pipeline and the
/// per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let name: String
    let sender: MacSender
    // The virtual display this session wants at the Mac's global origin,
    // reported by the sender once its capture is live.
    var mainDisplayID: CGDirectDisplayID?
    var audioStreaming = false
    let startedAt = Date()

    @Published var status = "Starting…"
    @Published var mbps = 0.0
    @Published var linkUp = true
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    @Published private(set) var hello: PhoneInfo

    var resolution: String { "\(hello.pixelsWide)×\(hello.pixelsHigh)" }

    init(id: String, name: String, hello: PhoneInfo, sender: MacSender) {
        self.id = id
        self.name = name
        self.hello = hello
        self.sender = sender
    }

    func update(hello: PhoneInfo) {
        self.hello = hello
    }
}
