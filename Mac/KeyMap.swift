import Carbon.HIToolbox
import CoreGraphics

enum KeyMap {

    static func keyCode(for name: String) -> CGKeyCode? {
        table[name]
    }

    static let table: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [:]

        let named: [String: Int] = [
            "escape": kVK_Escape,
            "tab": kVK_Tab,
            "return": kVK_Return,
            "enter": kVK_ANSI_KeypadEnter,
            "delete": kVK_Delete,
            "forwardDelete": kVK_ForwardDelete,
            "space": kVK_Space,
            "left": kVK_LeftArrow,
            "right": kVK_RightArrow,
            "up": kVK_UpArrow,
            "down": kVK_DownArrow,
            "home": kVK_Home,
            "end": kVK_End,
            "pageUp": kVK_PageUp,
            "pageDown": kVK_PageDown,
        ]
        for (name, code) in named { map[name] = CGKeyCode(code) }

        let functionKeys: [Int] = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() {
            map["f\(index + 1)"] = CGKeyCode(code)
        }

        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        ]
        for (name, code) in letters { map[name] = CGKeyCode(code) }

        let digits: [String: Int] = [
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        for (name, code) in digits { map[name] = CGKeyCode(code) }

        let punctuation: [String: Int] = [
            "-": kVK_ANSI_Minus,
            "=": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket,
            "\\": kVK_ANSI_Backslash,
            ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote,
            ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash,
            "`": kVK_ANSI_Grave,
            "*": kVK_ANSI_KeypadMultiply,
            "+": kVK_ANSI_KeypadPlus,
        ]
        for (name, code) in punctuation { map[name] = CGKeyCode(code) }

        return map
    }()
}
