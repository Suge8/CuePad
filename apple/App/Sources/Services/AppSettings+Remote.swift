import Foundation

/// 在 Mac 上操作（`MacRemote`）记在本机的：每台 Mac 在 UU 远程里绑的哪台电脑、上次连的哪台、正在等哪一次绑定回跳。
extension AppSettings {
    private enum RemoteKey {
        static let devices = "remoteDevices"
        static let lastHost = "remoteLastHost"
        static let pending = "remotePending"
    }

    /// Mac（`hostID`）→ UU 远程的加密设备标识。
    var remoteDevices: [String: String] {
        get { defaults.dictionary(forKey: RemoteKey.devices) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: RemoteKey.devices) }
    }

    /// 上次连的那台：有几台 Mac 时页顶那颗钮直接连它。
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
}
