#if os(macOS)
import Foundation

extension AppSettings.Key {
    static let setupOffered = "setupOffered"
    fileprivate static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置
}

extension AppSettings {
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
