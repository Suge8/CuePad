import CueStore
import Foundation

/// 不写发送记录、不算发给会话的话。已结束的会话 Mac 先在后台恢复再改。
/// 会话名只来自 Pi（会话记录的 `title`，规则 `PiSessionName`），界面不另存；改名在路上、没改成都由这条请求推出。
nonisolated enum PiRename {
    static func clean(_ name: String) -> String? {
        let name = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func title(of session: PiSessionState, request: DeliveryRequest?, at moment: Speech.Moment) -> String {
        guard let request, let name = request.config?.name else { return session.title }
        switch Speech.trip(request, at: moment) {
        case .sending, .sent: return name
        case .delivered: return session.modifiedAt > (request.completedAt ?? request.createdAt) ? session.title : name
        case .preparing, .failed, .unconfirmed: return session.title
        }
    }

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

extension PiSessionListItem {
    func shownTitle(at moment: Speech.Moment) -> String { PiRename.title(of: state, request: rename, at: moment) }

    /// 会话行、会话条与看板写的名字：绑着任务的是那个叶子的标题（任务标题是名字的唯一事实源），标题为空或没绑任务的是会话自己的名字。
    func name(at moment: Speech.Moment) -> String { task?.title.nonEmpty ?? shownTitle(at: moment) }
}
