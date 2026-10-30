import CueStore
import Foundation

/// 发出的新会话请求此刻的结果，以及认领到的会话（同步记录带着同一个标识）。iOS 的新会话输入框与 Mac 的开会话共用这一条判断。
nonisolated struct LaunchProgress: Sendable, Equatable {
    var request: DeliveryRequest?
    var claimed: Claimed?

    /// 认领到的会话：记录 id 与 Pi 的会话 id。
    struct Claimed: Sendable, Equatable {
        var id: UUID
        var sessionID: String
    }

    enum Phase: Equatable {
        case idle
        /// 请求在路上，或 Mac 还没执行完：发出没有、Mac 接没接手（`PiDelivery.Transit`）。
        case sending(PiDelivery.Transit)
        /// Mac 已启动 Pi，等它连上来。
        case opening
        case unconfirmed(String)
        /// 明确没能开成：Mac 报的原因。
        case failed(Speech.Failure)
        case claimed
    }

    func phase(at moment: Speech.Moment) -> Phase {
        if claimed != nil { return .claimed }
        guard let request else { return .idle }
        let trip = Speech.trip(request, at: moment)
        switch trip {
        case .preparing: return .idle
        case .sending, .sent: return .sending(.of(request, session: nil, trip: trip))
        case .delivered: return .opening
        case .unconfirmed(let reason): return .unconfirmed(reason)
        case .failed(let failure): return .failed(failure)
        }
    }

}

/// 请一台 Mac 在后台开新会话的那一次（Mac 的新会话表单与发给 Agent、手机的新会话输入框都经 `AppServices.launchSession`）：
/// 投送请求与这次生成的认领标识；会话连上时带着这个标识，进度按它读。
nonisolated struct SessionLaunch: Equatable, Sendable {
    let request: UUID
    let token: String

    func progress(from store: isolated CueStore) throws -> LaunchProgress {
        let claimed = try store.piSessionPage(PiSessionQuery(launchToken: token, limit: 1)).items.first
        return LaunchProgress(
            request: try store.deliveryRequest(request), claimed: claimed.map { .init(id: $0.id, sessionID: $0.state.sessionID) })
    }
}
