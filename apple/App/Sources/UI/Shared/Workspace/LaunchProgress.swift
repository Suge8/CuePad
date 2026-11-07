import CueStore
import Foundation

/// 发出的新会话请求此刻的结果，以及认领到的会话（同步记录带着同一个标识）。iOS 的新会话输入框与 Mac 的开会话共用这一条判断。
nonisolated struct LaunchProgress: Sendable, Equatable {
    /// 读的是哪一次（`SessionLaunch.request`）；还没读过为 nil。
    var launch: UUID?
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
        /// Mac 已启动 Pi，等它连上来（至多 `openingLimit`，过了按未确认）。
        case opening
        case unconfirmed(String)
        /// 明确没能开成：Mac 报的原因。
        case failed(Speech.Failure)
        /// 这一次的请求库里已经没有了（清理掉了），说不出结果。
        case missing
        case claimed
    }

    /// Mac 说开好了之后等会话连上来多久（从本机看到结果起，本机的钟）：同一段阶段期限。
    static let openingLimit = DeliveryRequest.phaseLimit
    static let notConnected = String(localized: "Mac 说已经开了，会话一直没连上来，结果没确认；可以再开")

    /// 等会话连上来的期限；不在等的为 nil。到点要重算一次（`NewSessionInput` 据此定闹钟）。
    func openingDeadline(at moment: Speech.Moment) -> Date? {
        guard claimed == nil, let request, Speech.trip(request, at: moment) == .delivered else { return nil }
        return (request.resultReceivedAt ?? request.completedAt ?? request.modifiedAt).addingTimeInterval(Self.openingLimit)
    }

    func phase(at moment: Speech.Moment) -> Phase {
        if claimed != nil { return .claimed }
        guard let request else { return launch == nil ? .idle : .missing }
        let trip = Speech.trip(request, at: moment)
        switch trip {
        case .preparing: return .idle
        case .sending, .sent: return .sending(.of(request, session: nil, trip: trip))
        case .delivered: return openingDeadline(at: moment).map { moment.now >= $0 } == true ? .unconfirmed(Self.notConnected) : .opening
        case .unconfirmed(let reason): return .unconfirmed(reason)
        case .failed(let failure): return .failed(failure)
        }
    }

    /// 新会话输入框锁不锁，只在这里定、由 `Speech.trip` 推出：正在写请求（`sending`）时锁；发出过（`launched`）就只在有期限的等待里锁——
    /// 到了服务器、等 Mac 派发或执行（期限到了 trip 就是未确认），与 Mac 开好后等会话连上（`openingDeadline`）。还没读到这一次的进度算在等。
    /// 其余都解锁、可以再开，任何情况都不会一直锁住：还没传上去（离线时没有期限，再开时撤回它，`AppServices.launchSession`）、
    /// 未确认（显示结果没确认；再开是你决定的，不是自动重发）、失败、库里已找不到它（清理掉了）。
    static func locksInput(sending: Bool, launched: SessionLaunch?, progress: LaunchProgress?, at moment: Speech.Moment) -> Bool {
        if sending { return true }
        guard let launched else { return false }
        guard let progress, progress.launch == launched.request else { return true }
        guard progress.claimed == nil, let request = progress.request else { return false }
        switch Speech.trip(request, at: moment) {
        case .sent, .preparing: return true
        case .delivered: return progress.phase(at: moment) == .opening
        case .sending, .unconfirmed, .failed: return false
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
            launch: request, request: try store.deliveryRequest(request), claimed: claimed.map { .init(id: $0.id, sessionID: $0.state.sessionID) })
    }
}

extension Workspace {
    /// 新会话输入框提交开场，并在再次提交时尝试撤回上一条尚未交出的请求。
    func launchSession(
        in project: UUID, prompt: String?, title: String, on host: String, card: UUID?, agent: AgentKind,
        model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, fast: Bool = false, replacing previous: UUID? = nil
    ) async throws -> SessionLaunch {
        try await services.launchSession(
            in: project, prompt: prompt, title: title, on: host, card: card, agent: agent,
            model: model, thinking: thinking, fast: fast, replacing: previous)
    }
}
