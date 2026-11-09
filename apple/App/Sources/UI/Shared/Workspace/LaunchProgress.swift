import CueStore
import Foundation

nonisolated struct LaunchProgress: Sendable, Equatable {
    var launch: UUID?
    var request: DeliveryRequest?
    var claimed: Claimed?
    var otherRequests: [DeliveryRequest] = []

    struct Claimed: Sendable, Equatable {
        var id: UUID
        var sessionID: String
    }

    enum Submission { case safe, waiting, confirm }

    enum Phase: Equatable {
        case idle
        case sending(PiDelivery.Transit)
        case opening
        case unconfirmed(String)
        case failed(Speech.Failure)
        /// 这一次的请求库里已经没有了（清理掉了），说不出结果。
        case missing
        case claimed

        /// 编辑和关闭不等投送；再次提交是否需要确认只由进度推出。
        var submission: Submission {
            switch self {
            case .idle, .failed: .safe
            case .sending(let transit): transit == .sending ? .safe : .waiting
            case .opening, .unconfirmed, .missing: .confirm
            case .claimed: .waiting
            }
        }
    }

    /// 当前一次失败也不能授权重做旧的未知请求；仍在等待当前回执时继续等。
    func submission(at moment: Speech.Moment) -> Submission {
        let current = phase(at: moment).submission
        return current == .waiting || otherRequests.isEmpty ? current : .confirm
    }

    func phase(at moment: Speech.Moment) -> Phase {
        if claimed != nil { return .claimed }
        guard let request else { return launch == nil ? .idle : .missing }
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

/// 认领标识：会话连上时带着它，进度按它读。
nonisolated struct SessionLaunch: Equatable, Sendable {
    let request: UUID
    let token: String

    func progress(from store: isolated CueStore) throws -> LaunchProgress {
        let claimed = try store.piSessionPage(PiSessionQuery(launchToken: token, limit: 1)).items.first
        let current = try store.deliveryRequest(request)
        let others = try current?.cardID.map { try store.unresolvedLaunches(for: $0).filter { $0.id != request } } ?? []
        return LaunchProgress(
            launch: request, request: current, claimed: claimed.map { .init(id: $0.id, sessionID: $0.state.sessionID) }, otherRequests: others)
    }
}
