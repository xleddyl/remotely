import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct KeyboardLayoutMap {

    struct Stroke: Equatable {
        let code: CGKeyCode
        let flags: CGEventFlags
    }

    static let unmapped = Stroke(code: 0, flags: [])

    let sourceID: String

    private let layoutData: Data
    private let strokes: [Character: Stroke]

    init(sourceID: String, layoutData: Data) {
        self.sourceID = sourceID
        self.layoutData = layoutData
        let combinations: [(carbon: UInt32, flags: CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        var table: [Character: Stroke] = [:]
        for combination in combinations {
            for code in UInt16(0)...127 {
                guard let produced = Self.translate(layoutData, code: code,
                                                    modifiers: combination.carbon),
                      produced.count == 1,
                      let character = produced.first,
                      let scalar = produced.unicodeScalars.first,
                      scalar.value >= 0x20, scalar.value != 0x7F,
                      table[character] == nil else { continue }
                table[character] = Stroke(code: CGKeyCode(code), flags: combination.flags)
            }
        }
        strokes = table
    }

    var mappedCharacterCount: Int { strokes.count }

    func stroke(for character: Character) -> Stroke? { strokes[character] }

    func character(producedBy stroke: Stroke) -> Character? {
        guard let produced = Self.translate(layoutData, code: UInt16(stroke.code),
                                            modifiers: Self.carbonModifiers(stroke.flags)),
              produced.count == 1 else { return nil }
        return produced.first
    }

    static func stroke(for character: Character, in map: KeyboardLayoutMap?) -> Stroke {
        map?.stroke(for: character) ?? unmapped
    }

    @MainActor
    static func current() -> KeyboardLayoutMap? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let id = property(source, kTISPropertyInputSourceID),
              let data = layoutData(source) else { return nil }
        return KeyboardLayoutMap(sourceID: id, layoutData: data)
    }

    @MainActor
    private static func property(_ source: TISInputSource, _ key: CFString!) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    @MainActor
    private static func layoutData(_ source: TISInputSource) -> Data? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    }

    private static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var carbon = 0
        if flags.contains(.maskShift) { carbon |= shiftKey }
        if flags.contains(.maskAlternate) { carbon |= optionKey }
        return UInt32(carbon >> 8)
    }

    private static func translate(_ layout: Data, code: UInt16, modifiers: UInt32) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(base, code, UInt16(kUCKeyActionDown), modifiers,
                                  UInt32(LMGetKbdType()), 0, &deadKeyState,
                                  characters.count, &length, &characters)
        }
        guard status == noErr, length > 0, deadKeyState == 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

final class KeyboardLayoutStore: @unchecked Sendable {

    static let shared = KeyboardLayoutStore()

    static let inputSourceChanged =
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    private let notifications: NotificationCenter
    private let lock = NSLock()
    private var map: KeyboardLayoutMap?
    private var observer: NSObjectProtocol?

    init(notifications: NotificationCenter = DistributedNotificationCenter.default()) {
        self.notifications = notifications
    }

    var snapshot: KeyboardLayoutMap? {
        lock.lock()
        defer { lock.unlock() }
        return map
    }

    func install(_ map: KeyboardLayoutMap?) {
        lock.lock()
        self.map = map
        lock.unlock()
    }

    func startTracking() {
        onMain { store in store.beginTracking() }
    }

    @MainActor
    private func beginTracking() {
        guard observer == nil else { return }
        observer = notifications.addObserver(
            forName: Self.inputSourceChanged, object: nil, queue: nil
        ) { [weak self] _ in
            self?.onMain { store in store.refresh() }
        }
        refresh()
    }

    @MainActor
    private func refresh() {
        install(KeyboardLayoutMap.current())
    }

    private func onMain(_ body: @escaping @MainActor (KeyboardLayoutStore) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
    }
}
