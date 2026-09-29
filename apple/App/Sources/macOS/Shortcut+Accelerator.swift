#if os(macOS)
import Carbon.HIToolbox

/// 快捷键的持久化格式：W3C code 加速键（`Control+Alt+Shift+Super+KeyK`），与 Electron 版一致，
/// 所以旧库里的 globalShortcut 可以直接采用。键位是物理键码，与键盘布局无关。
extension Shortcut {
    private static let modifierNames: [(name: String, modifier: Modifiers)] = [
        ("Control", .control), ("Alt", .option), ("Shift", .shift), ("Super", .command),
    ]

    private static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "Space": kVK_Space, "Enter": kVK_Return, "Tab": kVK_Tab, "Backquote": kVK_ANSI_Grave,
            "Minus": kVK_ANSI_Minus, "Equal": kVK_ANSI_Equal, "BracketLeft": kVK_ANSI_LeftBracket,
            "BracketRight": kVK_ANSI_RightBracket, "Backslash": kVK_ANSI_Backslash,
            "Semicolon": kVK_ANSI_Semicolon, "Quote": kVK_ANSI_Quote, "Comma": kVK_ANSI_Comma,
            "Period": kVK_ANSI_Period, "Slash": kVK_ANSI_Slash, "ArrowUp": kVK_UpArrow,
            "ArrowDown": kVK_DownArrow, "ArrowLeft": kVK_LeftArrow, "ArrowRight": kVK_RightArrow,
            "Home": kVK_Home, "End": kVK_End, "PageUp": kVK_PageUp, "PageDown": kVK_PageDown,
        ]
        let letters = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
            kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
            kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
            kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ]
        for (letter, code) in zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ", letters) { codes["Key\(letter)"] = code }
        let digits = [
            kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        for (digit, code) in digits.enumerated() { codes["Digit\(digit)"] = code }
        let functions = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        ]
        for (index, code) in functions.enumerated() { codes["F\(index + 1)"] = code }
        return codes
    }()

    /// 至少一个修饰键加一个受支持的主键；否则 nil。
    init?(accelerator: String) {
        var tokens = accelerator.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = tokens.popLast(), let code = Self.keyCodes[key], !tokens.isEmpty else { return nil }
        var modifiers: Modifiers = []
        for token in tokens {
            guard let entry = Self.modifierNames.first(where: { $0.name == token }) else { return nil }
            modifiers.insert(entry.modifier)
        }
        self.init(keyCode: UInt32(code), modifiers: modifiers)
    }

    var accelerator: String? {
        guard let key = Self.keyCodes.first(where: { $0.value == Int(keyCode) })?.key else { return nil }
        let names = Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.name)
        return (names + [key]).joined(separator: "+")
    }
}
#endif
