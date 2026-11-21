#if os(macOS)
import Foundation

extension AppSettings.Key {
    static let setupOffered = "setupOffered"
    fileprivate static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置
}

nonisolated struct HotkeySlot: Sendable {
    let key: String
    let defaultAccelerator: String

    static let main = HotkeySlot(key: "globalShortcut", defaultAccelerator: "Alt+Shift+Space")
    static let cue = HotkeySlot(key: "cueShortcut", defaultAccelerator: "Alt+Space")
}

extension AppSettings {
    func accelerator(_ slot: HotkeySlot) -> String { defaults.string(forKey: slot.key) ?? slot.defaultAccelerator }
    func setAccelerator(_ accelerator: String, for slot: HotkeySlot) { defaults.set(accelerator, forKey: slot.key) }

    var setupOffered: Bool {
        get { defaults.bool(forKey: Key.setupOffered) }
        set { defaults.set(newValue, forKey: Key.setupOffered) }
    }

    func windowFrame(for name: String) -> String? {
        defaults.string(forKey: Key.frameKeyPrefix + name)
    }

    func setWindowFrame(_ descriptor: String, for name: String) {
        defaults.set(descriptor, forKey: Key.frameKeyPrefix + name)
    }
}
#endif
