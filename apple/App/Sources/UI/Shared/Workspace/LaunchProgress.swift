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
        /// 还没有发出。
        case idle
        /// 请求在路上，或 Mac 还没执行完。
        case sending(DeliveryRequest)
        /// Mac 已启动 Pi，等它连上来。
        case opening
        case failed(String)
        case claimed
    }

    var phase: Phase {
        if claimed != nil { return .claimed }
        guard let request else { return .idle }
        if let failure = request.failure { return .failed(failure) }
        return request.status == .known(.succeeded) ? .opening : .sending(request)
    }

    static func read(request: UUID, token: String, from store: isolated CueStore) throws -> LaunchProgress {
        let claimed = try store.piSessionPage(PiSessionQuery(launchToken: token, limit: 1)).items.first
        return LaunchProgress(request: try store.deliveryRequest(request), claimed: claimed.map { Claimed(id: $0.id, sessionID: $0.state.sessionID) })
    }
}
