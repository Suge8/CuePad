#if os(macOS)
import Foundation

/// Mac 专属的偏好：窗口位置、首次打开的接入面板出现过没有。
extension AppSettings.Key {
    static let agentSetupShown = "agentSetupShown"
    fileprivate static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置
}

extension AppSettings {
    /// 首次打开的接入面板出现过没有（`Workspace.offerSetup`）：看过不接的不再弹，之后从 Cue 页的启用卡或设置里来。
    /// 键名不改：看过的人身上存的就是它。
    var setupShown: Bool {
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
