#if os(macOS)
import Foundation

extension AppSettings.Key {
    static let setupOffered = "setupOffered"
    fileprivate static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置
}

/// 一个全局快捷键存在哪个键下、没存过时用哪个（W3C code 形式，如 `Alt+Space`）。
nonisolated struct HotkeySlot: Sendable {
    let key: String
    let defaultAccelerator: String

    static let main = HotkeySlot(key: "globalShortcut", defaultAccelerator: "Alt+Shift+Space")
    /// 两个全局快捷键里它用得勤，默认给两键的 ⌥Space（各家的快速输入也是它）；"显示或隐藏 CuePad"错开一个 ⇧。
    static let cue = HotkeySlot(key: "cueShortcut", defaultAccelerator: "Alt+Space")
}

extension AppSettings {
    func accelerator(_ slot: HotkeySlot) -> String { defaults.string(forKey: slot.key) ?? slot.defaultAccelerator }
    func setAccelerator(_ accelerator: String, for slot: HotkeySlot) { defaults.set(accelerator, forKey: slot.key) }

    /// 看过不接的不再弹。
    var setupOffered: Bool {
        get { defaults.bool(forKey: Key.setupOffered) }
        set { defaults.set(newValue, forKey: Key.setupOffered) }
    }

    /// `NSWindow.frameDescriptor` 字符串。
    func windowFrame(for name: String) -> String? {
        defaults.string(forKey: Key.frameKeyPrefix + name)
    }

    func setWindowFrame(_ descriptor: String, for name: String) {
        defaults.set(descriptor, forKey: Key.frameKeyPrefix + name)
    }
}
#endif
