import CueStore
import Foundation

nonisolated extension PiSessionState {
    func isWaking(by delivery: DeliveryRequest?, at moment: Speech.Moment) -> Bool {
        PiDelivery.phase(of: delivery, for: self, at: moment) == .inTransit(.waking)
    }
}

nonisolated extension PiSessionState {
    /// 此刻同步不通时那台的在线记录可能只是没同步来，那台就是本机（刚启动、还没写下在线）也不算：都照旧说不准。
    func macOff(at moment: Speech.Moment) -> String? {
        guard let mac = offlineMac, !moment.isLocal(hostID), moment.reachableSince(hostID) != nil else { return nil }
        return mac
    }
}

nonisolated extension PiSessionListItem {
    func isCurrent(at moment: Speech.Moment) -> Bool {
        state.state != .known(.ended) || state.isWaking(by: delivery, at: moment)
    }

    static func undelivered(_ items: [PiSessionListItem], at moment: Speech.Moment) -> [String: Int] {
        Dictionary(items.compactMap { item in
            let count = item.undelivered(at: moment)
            return count > 0 ? (item.state.sessionID, count) : nil
        }) { first, _ in first }
    }
}

nonisolated extension PiSessionState {
    /// 待回复那一档是等得最久的在前，同会话条（`CueStore.sessionsAwaitingReply`）。
    /// `deliveries`：话在路上的与工作中同档，发出那一刻就挪到位。
    /// 不看有没有新回复：看一眼就让行换位置，列表会在手下跳。
    static func inListOrder<Item>(
        _ items: [Item], state: KeyPath<Item, PiSessionState>, deliveries: [String: DeliveryRequest] = [:], cue: CueDuty? = nil,
        at moment: Speech.Moment
    ) -> [Item] {
        items.enumerated()
            .map { index, item in
                let session = item[keyPath: state]
                let shown = PiShown(session, delivery: deliveries[session.sessionID], cue: cue, at: moment)
                let waited = shown.status == .awaitsReply ? session.stateSince : .distantPast
                return (rank: shown.rank, waited: waited, offset: index, item: item)
            }
            .sorted { ($0.rank, $0.waited, $0.offset) < ($1.rank, $1.waited, $1.offset) }
            .map(\.item)
    }

    var hasStarted: Bool { lastPrompt != nil || lastReply != nil || pendingPrompt != nil }
}

/// 会话状态只来自 Mac 同步回来的记录，发出后要等 Mac 执行、写回、再同步过来才变；话是本机当场写出的，所以显示状态把它算进去：发出即"发送中"，会话进入处理中后让位给会话状态。
nonisolated enum PiDelivery: Hashable, Sendable {
    case preparing(String)
    case inTransit(Transit)
    case delivered
    case failed(Speech.Failure)

    enum Transit: Hashable, Sendable {
        case sending
        case sent
        case delivering
        case waking
        case unconfirmed

        var label: String {
            switch self {
            case .sending: String(localized: "发送中")
            case .sent: String(localized: "已发出")
            case .delivering: String(localized: "送达中")
            case .waking: String(localized: "正在唤醒")
            case .unconfirmed: String(localized: "送达未确认")
            }
        }

        var note: String {
            switch self {
            case .sending: String(localized: "你的话发送中")
            case .sent: String(localized: "你的话已发出")
            case .delivering: String(localized: "你的话送达中")
            case .waking: String(localized: "你的话正在唤醒")
            case .unconfirmed: String(localized: "你的话送达未确认")
            }
        }

        static func of(_ request: DeliveryRequest, session: PiSessionState?, trip: Speech.Trip) -> Transit {
            if session?.state == .known(.ended) { return .waking }
            if !request.isWithdrawable { return .delivering }
            return trip == .sent ? .sent : .sending
        }
    }

    /// 会话状态的时间（`stateSince`）与送达时间（`completedAt`）都是 Mac 的钟；发出时间是发起设备的钟，只拿来判断"发出之后会话动起来了"，跨设备的钟差最多让"发送中"早一点让位。
    /// 送到了的请求不会一直挂着（发出的话进了对话、消息上了服务器就收走，别的请求过一会儿由执行它的 Mac 清理）；没能送达的留着（等你重发或移除），在你看过这个会话（`seen`，本机最后一次看它）之前一直显示，会话之后动过也不算数。
    static func phase(of request: DeliveryRequest?, for session: PiSessionState, seen: Date? = nil, at moment: Speech.Moment) -> PiDelivery? {
        guard let request, let mode = request.mode.known, DeliveryMode.toSession.contains(mode) else { return nil }
        let trip = Speech.trip(request, at: moment)
        switch trip {
        case .preparing(let reason): return .preparing(reason)
        case .unconfirmed: return mode == .retry ? nil : .inTransit(.unconfirmed)
        case .sending, .sent:
            // 发出之后才进入处理中，才算它在处理这句话；时间存到毫秒，同刻算作发出前就在跑（这句还没打断它）
            if session.runtimeState.isWorking && session.stateSince > request.createdAt { return nil }
            return .inTransit(.of(request, session: session, trip: trip))
        case .delivered:
            let caughtUp = session.runtimeState.isWorking || session.stateSince > (request.completedAt ?? request.createdAt)
                || session.answered(since: request.createdAt)
            return caughtUp ? nil : .delivered
        case .failed(let failure):
            return (seen ?? .distantPast) > (Speech.failedAt(request, at: moment) ?? moment.now) ? nil : .failed(failure)
        }
    }
}

/// 没看过的从 `since`（启用这条规则的时刻）起算，之前就停下的不算。看的时刻记在本机偏好（`AppSettings.markSeen`）。"标为未读"把看的时刻回拨到停下之前（`markedUnread`），规则启用前就停下的也行。
nonisolated enum PiUnread {
    static func isUnread(_ session: PiSessionState, seen: Date?, since: Date) -> Bool {
        isSettledReply(session) && session.stateSince > (seen ?? since)
    }

    static func canMarkUnread(_ session: PiSessionState, seen: Date?, since: Date) -> Bool {
        isSettledReply(session) && !isUnread(session, seen: seen, since: since)
    }

    static func markedUnread(_ session: PiSessionState) -> Date { session.stateSince.addingTimeInterval(-0.001) }

    private static func isSettledReply(_ session: PiSessionState) -> Bool {
        session.runtimeState == .known(.settled) && session.hasStarted
    }
}

/// 界面上一个会话（或一个项目）显示的状态，全 App 只在这里判定；说法、颜色、状态标、动效、排序也都只按 `status` 分。赭黄只留给在等你的（与"等你 N"同一条规则，`PiSessionState.asksYou`、`CueStore.cueTally`）。
nonisolated struct PiShown: Hashable, Sendable {
    var agentBusy: Bool {
        switch status {
        case .delivery(.preparing): false
        case .working, .asking, .delivery, .unknown: true
        default: false
        }
    }

    enum Status: Hashable, Sendable {
        case delivery(PiDelivery)
        case working(PiWorkState)
        case asking
        case awaitsReply
        case cueAsking
        case failed(PiFailure)
        case unread
        case idle
        case resting
        case fresh
        case ended
        case interrupted
        /// 没确认是因为它所在的 Mac 没开时带上那台的名字（`PiSessionState.macOff`）：说的是那台没开，同 Cue 那一句（`CuePresence.asleep`）。
        case unknown(macOff: String? = nil)
    }

    let status: Status
    var note: String?
    var clock: PiClock?
    var cue: String?
    var asksForWords = false
    /// 输出中只是这层显示、不是同步的状态：会话的由 `Workspace.shown`、`shownInHeader` 一处置位（列表、顶栏、菜单栏同一个说法），正在说的话上方那一行与 Mac 上 Cue 的状态那一句各自读自己的草稿；手机没有草稿，照常是思考中。
    var speaking = false

    func speaking(_ drafting: Bool) -> PiShown {
        var shown = self
        shown.speaking = drafting
        return shown
    }
}

nonisolated extension PiShown {
    init(
        _ session: PiSessionState, delivery: DeliveryRequest? = nil, unread: Bool = false, seen: Date? = nil, cue duty: CueDuty? = nil,
        at moment: Speech.Moment
    ) {
        let cue = duty?.name
        let own = PiClock.reading(session.runtimeState, stateSince: session.stateSince, busySince: session.busySince)
        let busy = session.runtimeState.isWorking || session.runtimeState == .known(.waitingForUser)
        var reported = Self.status(of: session.runtimeState, failure: session.failure?.known)
        if let mac = session.macOff(at: moment) { reported = .unknown(macOff: mac) }
        let asked = session.waitsForCue(duty) ? Status.cueAsking : reported
        switch PiDelivery.phase(of: delivery, for: session, seen: seen, at: moment) {
        case .failed(let failure):
            self.init(status: .delivery(.failed(failure)), clock: own, cue: cue)
        case let phase? where busy:
            let note = if case .inTransit(let transit) = phase { transit.note } else { nil as String? }
            self.init(status: asked, note: note, clock: own, cue: cue)
        case let phase?:
            let clock = delivery.map { phase == .inTransit(.unconfirmed) ? PiClock.ago($0.createdAt) : .sent(since: $0.createdAt) }
            self.init(status: .delivery(phase), clock: clock, cue: cue)
        case nil where session.runtimeState == .known(.settled):
            let rest: Status = session.awaitsReply(duty) ? .awaitsReply : duty != nil ? .resting : unread ? .unread : .idle
            self.init(status: session.hasStarted ? rest : .fresh, clock: own, cue: cue)
        case nil:
            self.init(status: asked, clock: own, cue: cue)
        }
        asksForWords = session.question?.kind == .known(.text)
    }

    init(_ session: PiSessionState, cue: CueDuty? = nil) {
        self.init(session, delivery: nil, cue: cue, at: .always())
    }

    init(state: Open<PiWorkState>) { status = Self.status(of: state, failure: nil) }

    private static func status(of state: Open<PiWorkState>, failure: PiFailure?) -> Status {
        switch state.known {
        case .thinking, .tool, .delegating, .compacting: .working(state.known!)
        case .waitingForUser: .asking
        case .error: .failed(failure ?? .other)
        case .settled: .idle
        case .ended: .ended
        case .interrupted: .interrupted
        case nil: .unknown()
        }
    }
}

extension Workspace {
    func shown(_ session: PiSessionState, delivery: DeliveryRequest?) -> PiShown {
        let settings = services.settings
        return PiShown(
            session, delivery: delivery, unread: settings.isUnread(session), seen: settings.sessionSeen[session.sessionID], cue: cueDuty,
            at: services.speech
        ).speaking(speaking(session))
    }

    /// 正在看的会话没有"有新回复"，没送到的话另写"N 句没送到"（`PiChat.undeliveredNote`），这里不再说一遍。
    func shownInHeader(_ session: PiSessionState, delivery: DeliveryRequest?) -> PiShown {
        PiShown(session, delivery: delivery, seen: .distantFuture, cue: cueDuty, at: services.speech).speaking(speaking(session))
    }

    /// 只随出字开始、结束通知，不随每个增量（`PiBridge.Slot.speaking`）。
    private func speaking(_ session: PiSessionState) -> Bool {
        #if os(macOS)
        services.pi.slot(sessionID: session.sessionID)?.speaking ?? false
        #else
        false
        #endif
    }

    var cueDuty: CueDuty? { services.liveSessions.cue }

    func shown(_ item: PiSessionListItem) -> PiShown { shown(item.state, delivery: item.delivery) }
}

nonisolated extension PiQuestion {
    var displayText: String {
        ([text] + options.map { "· \($0)" }).joined(separator: "\n")
    }
}
