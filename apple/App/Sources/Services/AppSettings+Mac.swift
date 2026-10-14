#if os(macOS)
import Foundation

/// Mac 专属的偏好：窗口位置、首次接入 Agent 的面板。
extension AppSettings.Key {
    static let agentSetupShown = "agentSetupShown"
    fileprivate static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置
}

extension AppSettings {
    /// 首次接入 Agent 的面板出现过没有（只在首次启动出现一次，之后在设置里接）。
    var agentSetupShown: Bool {
        get { defaults.bool(forKey: Key.agentSetupShown) }
        set { defaults.set(newValue, forKey: Key.agentSetupShown) }
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
