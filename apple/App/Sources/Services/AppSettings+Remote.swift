import Foundation

extension AppSettings {
    private enum RemoteKey {
        static let devices = "remoteDevices"
        static let lastHost = "remoteLastHost"
        static let binding = "remoteBinding"
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

    /// 在等回跳的那一次绑定：为哪台 Mac 绑，是不是为了看哪个会话的活预览（`Workspace.operate(on:viewing:)`）。
    struct RemoteBinding: Equatable {
        let nonce: String
        let host: String
        var viewing: String?
    }

    /// 只留最后一次（UU 也只处理最新的一次，旧的回 superseded）。记在偏好里：去 UU 选电脑时系统可能把 CuePad 收掉，
    /// 回跳可能由冷启动后的这一个、iPad 的另一个窗口接到。
    var remoteBinding: RemoteBinding? {
        get {
            guard let stored = defaults.dictionary(forKey: RemoteKey.binding) as? [String: String], let nonce = stored["nonce"], let host = stored["host"] else { return nil }
            return RemoteBinding(nonce: nonce, host: host, viewing: stored["viewing"])
        }
        set { defaults.set(newValue.map { ["nonce": $0.nonce, "host": $0.host, "viewing": $0.viewing].compactMapValues(\.self) }, forKey: RemoteKey.binding) }
    }

    /// 用 UU 远程到 Mac 上看着活预览的会话 → 那台 Mac：回到 CuePad 时请它把铺满的预览放回去（`LiveRemote.comeBack`）。
    /// 记在偏好里：看的那段时间系统可能把 CuePad 收掉。
    var remoteViewing: [String: String] {
        get { defaults.dictionary(forKey: RemoteKey.viewing) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: RemoteKey.viewing) }
    }
}
