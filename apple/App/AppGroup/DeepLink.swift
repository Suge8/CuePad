import Foundation

/// 小组件、分享扩展与实时活动打开主 App 的链接：`cuepad://speak`、`cuepad://project/<id>`、`cuepad://card/<id>`、`cuepad://cue`、`cuepad://session/<id>`。
nonisolated enum DeepLink: Equatable, Sendable {
    static let scheme = "cuepad"

    /// 打开 Cue 页，"对 Cue 说"拿到焦点（随手记也在那里说）。
    case speak
    case project(UUID)
    case card(UUID)
    case cue
    /// 打开一个会话（会话状态记录的 id，`PiSessionState.id`）：实时活动里会话在问的那件"打开"。
    case session(UUID)
    /// 网易 UU 远程绑定完回跳（`MacRemote`）：选好的电脑的加密标识，或失败的错误码；`nonce` 认是哪一次绑定。
    case remoteBound(device: String?, error: String?, nonce: String?)
    /// 网易 UU 远程远控失败回跳（`MacRemote.control`）：哪台 Mac、什么原因；成功的回跳不认（没什么要做）。
    case remoteFailed(host: String?, reason: String)

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        switch (host, parts.count) {
        case ("speak", 0):
            self = .speak
        case ("cue", 0):
            self = .cue
        case ("project", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .project(id)
        case ("card", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .card(id)
        case ("session", 1):
            guard let id = UUID(uuidString: parts[0]) else { return nil }
            self = .session(id)
        case ("uu-bound", 0):
            self = .remoteBound(device: value("anonymous_device_id"), error: value("error"), nonce: value("nonce"))
        case ("uu-control", 0):
            guard value("status") == "failure" else { return nil }
            self = .remoteFailed(host: value("host"), reason: value("reason") ?? "connect_failed")
        default:
            return nil
        }
    }

    var url: URL {
        switch self {
        case .speak: URL(string: "cuepad://speak")!
        case .project(let id): URL(string: "cuepad://project/\(id.uuidString.lowercased())")!
        case .card(let id): URL(string: "cuepad://card/\(id.uuidString.lowercased())")!
        case .cue: URL(string: "cuepad://cue")!
        case .session(let id): URL(string: "cuepad://session/\(id.uuidString.lowercased())")!
        case .remoteBound(let device, let error, let nonce):
            Self.remoteCallback.appending(present: [("anonymous_device_id", device), ("error", error), ("nonce", nonce)])
        case .remoteFailed(let host, let reason): Self.remoteControlled.appending(present: [("host", host), ("status", "failure"), ("reason", reason)])
        }
    }

    /// 交给 UU 远程的回跳地址（`MacRemote.authorize`）：它把结果接在后面打开。
    static let remoteCallback = URL(string: "cuepad://uu-bound")!

    /// 远控的回跳地址（`MacRemote.control`）：UU 保留它原有的 `host`，把 `status`、`reason` 接在后面。
    static func remoteControlCallback(host: String) -> URL {
        remoteControlled.appending(present: [("host", host)])
    }

    private static let remoteControlled = URL(string: "cuepad://uu-control")!
}

nonisolated private extension URL {
    /// 只接有值的参数。
    func appending(present items: [(String, String?)]) -> URL {
        appending(queryItems: items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } })
    }
}
