import CueStore
import Foundation

/// 改会话名：会话设置，与改模型、思考强度同一条路——一条带名字的配置请求（`PiConfig.name`，投送方式 `config`），
/// 扩展用 Pi 设置会话名的接口执行；不写发送记录、不算发给会话的话。已结束的会话 Mac 先在后台恢复再改。
/// 会话名只来自 Pi（会话记录的 `title`，规则 `PiSessionName`），界面不另存；改名在路上、没改成都由这条请求推出。
nonisolated enum PiRename {
    /// 新名整理成一行（Pi 的会话名是单行），空的是 nil。
    static func clean(_ name: String) -> String? {
        let name = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 此刻显示的会话名：最近一条改名（`request`）还在路上时是新名；送到了而会话记录在那之后还没写过
    /// （Pi 改了名、Mac 还没同步过来）也是新名；之后、以及没改成时以会话记录为准。到哪了按 `Speech`。
    static func title(of session: PiSessionState, request: DeliveryRequest?, at moment: Speech.Moment) -> String {
        guard let request, let name = request.config?.name else { return session.title }
        switch Speech.trip(request, at: moment) {
        case .sending, .sent: return name
        case .delivered: return session.modifiedAt > (request.completedAt ?? request.createdAt) ? session.title : name
        case .preparing, .failed, .unconfirmed: return session.title
        }
    }

    /// 改名还在路上（行上写"正在改名"）。
    static func isPending(_ request: DeliveryRequest?, at moment: Speech.Moment) -> Bool {
        guard let request, request.isRename else { return false }
        return Speech.trip(request, at: moment).inTransit
    }

    /// 没改成（行上写"没能改名"），留到本机看过这个会话（`seen`）为止（同没能送达的话，`PiDelivery.phase`）。
    static func failed(_ request: DeliveryRequest?, seen: Date?, at moment: Speech.Moment) -> Bool {
        guard let request, request.isRename, let failedAt = Speech.failedAt(request, at: moment) else { return false }
        return (seen ?? .distantPast) <= failedAt
    }
}

extension AppServices {
    /// 让 Pi 把会话改名（写一条发给它所在 Mac 的配置请求，立即上传）。新名为空时不写。
    @discardableResult
    func rename(_ session: PiSessionState, to name: String) async throws -> DeliveryRequest {
        guard let name = PiRename.clean(name) else { throw CueStoreError.blankDeliveryContent }
        return try await configure(PiConfig(name: name), for: session)
    }
}
