import UIKit

enum WireKeyMap {

    static func modifiers(from flags: UIKeyModifierFlags) -> WireModifiers {
        var result: WireModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.alternate) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.alphaShift) { result.insert(.capsLock) }
        return result
    }

    static func isModifierKey(_ key: UIKey) -> Bool {
        modifierUsages.contains(key.keyCode)
    }

    static func name(for key: UIKey) -> String? {
        if let named = namedKeys[key.keyCode] { return named }
        if let base = baseCharacters[key.keyCode] { return base }
        return name(forCharacter: key.charactersIgnoringModifiers)
    }

    static func name(forCharacter characters: String) -> String? {
        let lowered = characters.lowercased()
        if lowered == " " { return "space" }
        guard lowered.count == 1, printableBaseCharacters.contains(lowered) else { return nil }
        return lowered
    }

    static func typedText(for key: UIKey) -> String? {
        let characters = key.characters
        guard !characters.isEmpty else { return nil }
        for scalar in characters.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    private static let modifierUsages: Set<UIKeyboardHIDUsage> = [
        .keyboardLeftControl, .keyboardLeftShift, .keyboardLeftAlt, .keyboardLeftGUI,
        .keyboardRightControl, .keyboardRightShift, .keyboardRightAlt, .keyboardRightGUI,
        .keyboardCapsLock, .keyboardLockingCapsLock,
    ]

    private static let namedKeys: [UIKeyboardHIDUsage: String] = [
        .keyboardEscape: "escape",
        .keyboardTab: "tab",
        .keyboardReturnOrEnter: "return",
        .keypadEnter: "enter",
        .keyboardDeleteOrBackspace: "delete",
        .keyboardDeleteForward: "forwardDelete",
        .keyboardSpacebar: "space",
        .keyboardLeftArrow: "left",
        .keyboardRightArrow: "right",
        .keyboardUpArrow: "up",
        .keyboardDownArrow: "down",
        .keyboardHome: "home",
        .keyboardEnd: "end",
        .keyboardPageUp: "pageUp",
        .keyboardPageDown: "pageDown",
        .keyboardF1: "f1", .keyboardF2: "f2", .keyboardF3: "f3", .keyboardF4: "f4",
        .keyboardF5: "f5", .keyboardF6: "f6", .keyboardF7: "f7", .keyboardF8: "f8",
        .keyboardF9: "f9", .keyboardF10: "f10", .keyboardF11: "f11", .keyboardF12: "f12",
        .keyboardF13: "f13", .keyboardF14: "f14", .keyboardF15: "f15", .keyboardF16: "f16",
        .keyboardF17: "f17", .keyboardF18: "f18", .keyboardF19: "f19", .keyboardF20: "f20",
    ]

    private static let baseCharacters: [UIKeyboardHIDUsage: String] = [
        .keyboardA: "a", .keyboardB: "b", .keyboardC: "c", .keyboardD: "d",
        .keyboardE: "e", .keyboardF: "f", .keyboardG: "g", .keyboardH: "h",
        .keyboardI: "i", .keyboardJ: "j", .keyboardK: "k", .keyboardL: "l",
        .keyboardM: "m", .keyboardN: "n", .keyboardO: "o", .keyboardP: "p",
        .keyboardQ: "q", .keyboardR: "r", .keyboardS: "s", .keyboardT: "t",
        .keyboardU: "u", .keyboardV: "v", .keyboardW: "w", .keyboardX: "x",
        .keyboardY: "y", .keyboardZ: "z",
        .keyboard1: "1", .keyboard2: "2", .keyboard3: "3", .keyboard4: "4",
        .keyboard5: "5", .keyboard6: "6", .keyboard7: "7", .keyboard8: "8",
        .keyboard9: "9", .keyboard0: "0",
        .keyboardHyphen: "-", .keyboardEqualSign: "=",
        .keyboardOpenBracket: "[", .keyboardCloseBracket: "]",
        .keyboardBackslash: "\\", .keyboardNonUSBackslash: "\\",
        .keyboardSemicolon: ";", .keyboardQuote: "'", .keyboardGraveAccentAndTilde: "`",
        .keyboardComma: ",", .keyboardPeriod: ".", .keyboardSlash: "/",
        .keypad1: "1", .keypad2: "2", .keypad3: "3", .keypad4: "4", .keypad5: "5",
        .keypad6: "6", .keypad7: "7", .keypad8: "8", .keypad9: "9", .keypad0: "0",
        .keypadSlash: "/", .keypadAsterisk: "*", .keypadHyphen: "-",
        .keypadPlus: "+", .keypadPeriod: ".", .keypadEqualSign: "=",
    ]

    private static let printableBaseCharacters: Set<String> = {
        var set = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        for symbol in ["-", "=", "[", "]", "\\", ";", "'", "`", ",", ".", "/", "*", "+"] {
            set.insert(symbol)
        }
        return set
    }()
}

final class KeyboardInputView: UIView, UIKeyInput {

    var onText: ((String) -> Void)?
    var onKeyName: ((String) -> Void)?
    var onWordDelete: (() -> Void)?
    var onPresses: ((Set<UIPress>, Bool) -> Bool)?
    var onResign: (() -> Void)?

    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var isSecureTextEntry: Bool = true
    var textContentType: UITextContentType! = UITextContentType(rawValue: "")

    private var deleteStreak = 0
    private var lastDeleteAt: CFTimeInterval = 0

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            onKeyName?("return")
            return
        }
        onText?(text)
    }

    func deleteBackward() {
        let now = CACurrentMediaTime()
        deleteStreak = now - lastDeleteAt < 0.2 ? deleteStreak + 1 : 1
        lastDeleteAt = now
        if deleteStreak >= 15 {
            onWordDelete?()
        } else {
            onKeyName?("delete")
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, true) == true { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) == true { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if onPresses?(presses, false) == true { return }
        super.pressesCancelled(presses, with: event)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
