import Foundation

extension AppSettings {
    private enum RemoteKey {
        static let devices = "remoteDevices"
        static let lastHost = "remoteLastHost"
        static let pending = "remotePending"
        static let viewing = "remoteViewing"
    }

    /// Mac（`hostID`）→ UU 远程的加密设备标识。
    var remoteDevices: [String: String] {
        get { defaults.dictionary(forKey: RemoteKey.devices) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: RemoteKey.devices) }
    }

    var remoteLastHost: String? {
        get { defaults.string(forKey: RemoteKey.lastHost) }
        set { defaults.set(newValue, forKey: RemoteKey.lastHost) }
    }

    /// 在等回跳的那一次绑定：`nonce` → 为哪台 Mac 绑。只留最后一次（UU 也只处理最新的一次，旧的回 superseded）。
    /// 记在偏好里：去 UU 选电脑时系统可能把 CuePad 收掉，回跳时冷启动也认得出。
    var remotePending: [String: String] {
        get { defaults.dictionary(forKey: RemoteKey.pending) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: RemoteKey.pending) }
    }

    /// 用 UU 远程到 Mac 上看着活预览的会话 → 那台 Mac：回到 CuePad 时请它把铺满的预览放回去（`Workspace.returnFromMac`）。
    /// 记在偏好里：看的那段时间系统可能把 CuePad 收掉。
    var remoteViewing: [String: String] {
        get { defaults.dictionary(forKey: RemoteKey.viewing) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: RemoteKey.viewing) }
    }
}
