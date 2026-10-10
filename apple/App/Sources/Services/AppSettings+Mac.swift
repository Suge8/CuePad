#if os(macOS)
import Foundation

/// Mac 专属的偏好：窗口位置、命令行工具的首次提示。
extension AppSettings.Key {
    static let commandLineToolPrompted = "commandLineToolPrompted"
    fileprivate static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置
}

extension AppSettings {
    /// 是否已经提示过安装命令行工具（只在首次启动提示一次）。
    var commandLineToolPrompted: Bool {
        get { defaults.bool(forKey: Key.commandLineToolPrompted) }
        set { defaults.set(newValue, forKey: Key.commandLineToolPrompted) }
    }

    /// 窗口位置（`NSWindow.frameDescriptor` 字符串）：设备本地偏好，与其他偏好同处一个存储。
    func windowFrame(for name: String) -> String? {
        defaults.string(forKey: Key.frameKeyPrefix + name)
    }

    func setWindowFrame(_ descriptor: String, for name: String) {
        defaults.set(descriptor, forKey: Key.frameKeyPrefix + name)
    }
}
#endif
