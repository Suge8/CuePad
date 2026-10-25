import CueStore
import Foundation

nonisolated extension PiSessionState {
    /// 已结束、发给它的话（`delivery`，最近一条）正在路上：它所在的 Mac 正在唤醒它（`PiDelivery.Transit.waking`）。
    func isWaking(by delivery: DeliveryRequest?, at moment: Speech.Moment) -> Bool {
        PiDelivery.phase(of: delivery, for: self, at: moment) == .inTransit(.waking)
    }
}

nonisolated extension PiSessionListItem {
    /// 列在"现在"（"在做"、Agent 页）：没结束的，与正在唤醒的——唤醒中当场列出、写"正在唤醒"，上了桥就是在线的那一行。
    func isCurrent(at moment: Speech.Moment) -> Bool {
        state.state != .known(.ended) || state.isWaking(by: delivery, at: moment)
    }

    /// 此刻没能送达的话有几句，按 Pi 的会话 id（只留有的）：手里只有会话记录的行（Mac 菜单栏、⌘K、项目页 Agent 栏）按它找自己的数。
    static func undelivered(_ items: [PiSessionListItem], at moment: Speech.Moment) -> [String: Int] {
        Dictionary(items.compactMap { item in
            let count = item.undelivered(at: moment)
            return count > 0 ? (item.state.sessionID, count) : nil
        }) { first, _ in first }
    }
}

nonisolated extension PiSessionState {
    /// 会话列表的顺序（Agent 页、"在做"）：要你注意的在前（`PiShown.rank`），同一档保持原来的先后（最近进入当前状态的在前）；
    /// 待回复那一档是等得最久的在前，同 Cue 页的待回复提示（`CueStore.sessionsAwaitingReply`）。
    /// `deliveries` 是发给各会话（按 Pi 的会话 id）的最近一条投送请求：话在路上的与工作中同档，发出那一刻就挪到位。
    /// 不看有没有新回复：看一眼就让行换位置，列表会在手下跳。
    /// `cue`：Cue 在值班时的那一份（`LiveSessions.cue`），等它回答的与在跑的同档（`PiShown.Status.cueAsking`），它留给你回的（待回复）排最前。
    /// `moment`：此刻（话超时就是没能送达）。
    /// `state`：一项的会话（会话本身是 `\.self`）。
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

    /// 说过话：对话里有过一轮（做完的或进行中的）。终端里刚开、还没说过话的会话没有，它停在空闲不是"该你了"。
    var hasStarted: Bool { lastPrompt != nil || lastReply != nil || pendingPrompt != nil }
}

/// 发给会话、还没被它的状态吸收的那条话在会话行上的样子。到哪了只读说的话那条规则（`Speech`，含一直没发出与超时）：
/// 在路上（发送中、已发出）、已送达、没能送达；在路上怎么说（`Transit`）只是展示。会话状态只来自 Mac 同步回来的记录，发出后要等 Mac 执行、写回、
/// 再同步过来才变；话是本机当场写出的，所以显示状态把它算进去：发出即"发送中"，会话进入处理中后让位给会话状态。
nonisolated enum PiDelivery: Hashable, Sendable {
    case inTransit(Transit)
    /// 送到了，会话状态还没跟上。
    case delivered
    case failed(Speech.Failure)

    /// 还在路上的话此刻怎么说（会话行的小标记、会话页气泡下面、新会话浮框同一套）。
    enum Transit: Hashable, Sendable {
        /// 还没离开这台设备（`Speech.Trip.sending`）。
        case sending
        /// 服务器收下了，Mac 还没接手（`Speech.Trip.sent`）。
        case sent
        /// Mac 接手了，正在送达。
        case delivering
        /// 发给已结束的会话：Mac 先在后台唤醒它。
        case waking

        var label: String {
            switch self {
            case .sending: "发送中"
            case .sent: "已发出"
            case .delivering: "送达中"
            case .waking: "正在唤醒"
            }
        }

        /// `session` 是收话的会话；开新会话的请求没有。`trip` 是这条请求此刻到哪了（在路上的那两种）。
        static func of(_ request: DeliveryRequest, session: PiSessionState?, trip: Speech.Trip) -> Transit {
            if session?.state == .known(.ended) { return .waking }
            if !request.isWithdrawable { return .delivering }
            return trip == .sent ? .sent : .sending
        }
    }

    /// `request` 是发给 `session` 的最近一条（`DeliveryMode.toSession` 的方式）。会话状态的时间（`stateSince`）与送达时间
    /// （`completedAt`）都是 Mac 的钟；发出时间是发起设备的钟，只拿来判断"发出之后会话动起来了"，跨设备的钟差最多让"发送中"早一点让位。
    /// 送到了的请求不会一直挂着（发出的话进了对话就随之收走，别的请求过一会儿由执行它的 Mac 清理）；没能送达的留着（等你重发或移除），
    /// 在你看过这个会话（`seen`，本机最后一次看它）之前一直显示，会话之后动过也不算数。
    static func phase(of request: DeliveryRequest?, for session: PiSessionState, seen: Date? = nil, at moment: Speech.Moment) -> PiDelivery? {
        guard let request, let mode = request.mode.known, DeliveryMode.toSession.contains(mode) else { return nil }
        let trip = Speech.trip(request, at: moment)
        switch trip {
        case .sending, .sent:
            // 发出之后才进入处理中，才算它在处理这句话；时间存到毫秒，同刻算作发出前就在跑（这句还没打断它）
            if session.state.isWorking && session.stateSince > request.createdAt { return nil }
            return .inTransit(.of(request, session: session, trip: trip))
        case .delivered:
            // 等会话状态跟上（进入处理中，或在送达之后变过）就让位
            let caughtUp = session.state.isWorking || session.stateSince > (request.completedAt ?? request.createdAt)
            return caughtUp ? nil : .delivered
        case .failed(let failure):
            return (seen ?? .distantPast) > (Speech.failedAt(request, at: moment) ?? moment.now) ? nil : .failed(failure)
        }
    }
}

/// 做完了但你还没看：Pi 做完过一轮、停在空闲，且停下的时间晚于本机最后一次看这个会话；
/// 没看过的从 `since`（启用这条规则的时刻）起算，之前就停下的不算。看的时刻记在本机偏好（`AppSettings.markSeen`）。
/// "标为未读"把看的时刻回拨到停下之前（`markedUnread`），规则启用前就停下的也行。
nonisolated enum PiUnread {
    static func isUnread(_ session: PiSessionState, seen: Date?, since: Date) -> Bool {
        isSettledReply(session) && session.stateSince > (seen ?? since)
    }

    /// 能标为未读：做完一轮停在空闲、此刻不是未读。
    static func canMarkUnread(_ session: PiSessionState, seen: Date?, since: Date) -> Bool {
        isSettledReply(session) && !isUnread(session, seen: seen, since: since)
    }

    /// 标为未读后记下的"看过"时刻：停下之前一刻。
    static func markedUnread(_ session: PiSessionState) -> Date { session.stateSince.addingTimeInterval(-0.001) }

    private static func isSettledReply(_ session: PiSessionState) -> Bool {
        session.state == .known(.settled) && session.hasStarted
    }
}

/// 界面上一个会话（或一个项目）显示的状态，全 App 只在这里判定：会话行、项目状态点、会话页顶栏、任务上的会话状态、
/// Mac 侧栏与菜单栏、发送目标都经它。说法、颜色、状态标、动效、排序也都只按 `status` 分。
/// 判定的先后：没能送达（你没看过）在最前；会话自己在跑或在等你确认时就是它的状态，发给它的话还在路上只是一个小标记（`note`）；
/// 会话停着时话在路上就说路上到哪了（`PiDelivery`）；其余按 Pi 报的状态，停在空闲时再分——
/// 还没说过话是"新会话"，做完一轮你还没看是"有新回复"（`PiUnread`），看过是"该你了"（轮到你说下一句）；
/// Cue 在值班（`CueProfile.onDuty`）时接手的是 Cue，只说"歇着"，它把这次停下留给你回的是"待回复"（`PiSessionState.awaitsReply`）；会话等的回答 CuePad 答得了时等的也是 Cue
/// （"等 Cue 回答"，中性墨色，`PiSessionState.waitsForCue`），赭黄只留给在等你的（与"等你 N"同一条规则，`PiSessionState.asksYou`、`CueStore.cueTally`）。计时读哪一种（`clock`）也在这里定。
nonisolated struct PiShown: Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case delivery(PiDelivery)
        /// 思考、运行工具、等子代理、压缩上下文。
        case working(PiWorkState)
        case asking
        /// 歇着，Cue 值班时把这次停下留给了你回（`PiSessionState.awaitsReply`）。
        case awaitsReply
        /// 在等回答，等的是 Cue（`PiSessionState.waitsForCue`），不是你。
        case cueAsking
        case failed
        case unread
        case idle
        /// Cue 在值班时歇着：不催你（没有"有新回复""该你了"）。
        case resting
        case fresh
        case ended
        /// 做到一半被打断（进程没了）：停着，说一句它就接着做。
        case interrupted
        /// 其他版本写入、本版本不认识的状态。
        case unknown
    }

    let status: Status
    /// 会话在跑时还在路上的话："你的话发送中"、"你的话送达中"。
    var note: String?
    /// 计时；只有状态、没有会话的（子代理、样板）没有。
    var clock: PiClock?
    /// 值班的 Cue 的名字（用户起的）；Cue 不在值班为 nil。
    var cue: String?
    /// 在等你时问的是要你填一段文字（`PiQuestionKind.text`）："等你回答"；是或否、选一个是"等你确认"。
    var asksForWords = false
    /// 这台 Mac 上它此刻有正在说的话（会话的 `PiBridge.Slot.draft`、Cue 的 `CueKeeper.speech`）："思考中"说成"输出中"。
    /// 输出中只是这层显示、不是同步的状态：会话的由 `Workspace.shown`、`shownInHeader` 一处置位（列表、顶栏、菜单栏同一个说法），
    /// 正在说的话上方那一行与 Mac 上 Cue 的状态那一句各自读自己的草稿；手机没有草稿，照常是思考中。
    var speaking = false

    func speaking(_ drafting: Bool) -> PiShown {
        var shown = self
        shown.speaking = drafting
        return shown
    }
}

nonisolated extension PiShown {
    /// `cue`：Cue 在值班时的那一份（`LiveSessions.cue`，见 `Workspace.shown`）；`moment`：此刻（`AppServices.speech`）。
    init(
        _ session: PiSessionState, delivery: DeliveryRequest? = nil, unread: Bool = false, seen: Date? = nil, cue duty: CueDuty? = nil,
        at moment: Speech.Moment
    ) {
        let cue = duty?.name
        let own = PiClock.reading(session.state, stateSince: session.stateSince, busySince: session.busySince)
        let busy = session.state.isWorking || session.state == .known(.waitingForUser)
        let reported = Self.status(of: session.state)
        let asked = session.waitsForCue(duty) ? Status.cueAsking : reported
        switch PiDelivery.phase(of: delivery, for: session, seen: seen, at: moment) {
        case .failed(let failure):
            self.init(status: .delivery(.failed(failure)), clock: own, cue: cue)
        case let phase? where busy:
            let note = if case .inTransit(let transit) = phase { "你的话\(transit.label)" } else { nil as String? }
            self.init(status: asked, note: note, clock: own, cue: cue)
        case let phase?:
            self.init(status: .delivery(phase), clock: delivery.map { .sent(since: $0.createdAt) }, cue: cue)
        case nil where session.state == .known(.settled):
            let rest: Status = session.awaitsReply(duty) ? .awaitsReply : duty != nil ? .resting : unread ? .unread : .idle
            self.init(status: session.hasStarted ? rest : .fresh, clock: own, cue: cue)
        case nil:
            self.init(status: asked, clock: own, cue: cue)
        }
        asksForWords = session.question?.kind == .known(.text)
    }

    /// 没有发给它的话在路上（会话页顶栏、对话里的会话卡）：只按会话自己的状态，不涉及此刻。
    init(_ session: PiSessionState, cue: CueDuty? = nil) {
        self.init(session, delivery: nil, cue: cue, at: .always())
    }

    /// 只有 Pi 报的状态（子代理、样板）：空闲按看过处理。
    init(state: Open<PiWorkState>) { status = Self.status(of: state) }

    private static func status(of state: Open<PiWorkState>) -> Status {
        switch state.known {
        case .thinking, .tool, .delegating, .compacting: .working(state.known!)
        case .waitingForUser: .asking
        case .error: .failed
        case .settled: .idle
        case .ended: .ended
        case .interrupted: .interrupted
        case nil: .unknown
        }
    }
}

nonisolated extension PiShown {
    var label: String {
        switch status {
        case .delivery(.inTransit(let transit)): transit.label
        case .delivery(.delivered): "已送达"
        case .delivery(.failed): "没能送达"
        case .working(.tool): "运行工具"
        case .working(.delegating): "子代理工作中"
        case .working(.compacting): "正在压缩上下文"
        case .working: speaking ? "输出中" : CueNow.thinking
        case .asking: "等你\(waitWord)"
        case .awaitsReply: "待回复"
        case .cueAsking: "等 \(cue ?? "") 回答"
        case .failed: "出错"
        case .unread: "有新回复"
        case .idle: "该你了"
        case .resting: "歇着"
        case .fresh: "新会话"
        case .ended: "已结束"
        case .interrupted: "被打断"
        case .unknown: "未知状态"
        }
    }

    /// 只有一个状态标时它说的是什么（读屏标签、悬停提示、项目长按菜单的标题、任务上的会话状态）。
    var presence: String {
        switch status {
        case .delivery(.inTransit(.waking)): "正在唤醒 Agent"
        case .delivery(.failed): "没能送达 Agent"
        case .delivery: "正在发给 Agent"
        case .working(.compacting): "Agent 正在压缩上下文"
        case .working: "Agent 正在工作"
        case .asking: "Agent 等你\(waitWord)"
        case .awaitsReply: "Agent 在等你回复"
        case .cueAsking: "Agent 在等 \(cue ?? "") 回答"
        case .failed: "Agent 出错"
        case .unread: "Agent 有新回复"
        case .idle: "Agent 在等你说下一句"
        case .resting: "Agent 歇着"
        case .fresh: "Agent 新会话"
        case .ended: "Agent 会话已结束"
        case .interrupted: "Agent 被打断"
        case .unknown: "Agent 状态未知"
        }
    }

    /// 在等你做的事："回答"（填文字）或"确认"（是否、选择）。
    var waitWord: String { asksForWords ? "回答" : "确认" }

    /// 名字与状态词加粗：做完了你还没看。
    var isUnread: Bool { status == .unread }

    /// 此刻显示为没能送达时的原因（会话行、项目"此刻"、任务浮窗写它）。
    var undelivered: Speech.Failure? { if case .delivery(.failed(let failure)) = status { failure } else { nil } }

    /// 在跑：工作中，或话在路上、已送达而会话还没跟上（没能送达的不算）——状态色、动效、排序与区头"N 个在跑"同一档。
    var isRunning: Bool {
        switch status {
        case .working, .delivery(.inTransit), .delivery(.delivered): true
        default: false
        }
    }

    /// 会话列表的档：待回复（Cue 页的待回复提示点进来看的就是它们）→ 等你确认 → 出错与没能送达 → 工作中与话在路上 → 停下的 → 已结束。
    var rank: Int {
        switch status {
        case .awaitsReply: 0
        case .asking: 1
        case .failed, .delivery(.failed): 2
        case .working, .delivery, .cueAsking: 3
        case .unread, .idle, .resting, .fresh, .interrupted, .unknown: 4
        case .ended: 5
        }
    }

    /// 选会话时排在前面的（发给 Agent 的会话选单）：等你确认与待回复 → 出错 → 有新回复 → 工作中 → 停下的 → 已结束。
    var urgency: Int {
        switch status {
        case .asking, .awaitsReply: 6
        case .failed, .delivery(.failed): 5
        case .unread: 4
        case .working, .delivery, .cueAsking: 2
        case .idle, .resting, .fresh, .interrupted, .unknown: 1
        case .ended: 0
        }
    }
}

nonisolated extension PiShown {
    /// 要你动手：等你确认、待回复、出错、没能送达。只有它们带彩色。
    var needsYou: Bool {
        switch status {
        case .asking, .awaitsReply, .failed, .delivery(.failed): true
        default: false
        }
    }
}

extension Workspace {
    /// 这个会话在本机界面上显示的状态；`delivery` 是发给它的最近一条投送请求（`PiSessionListItem.delivery`）。
    /// 有没有新回复按本机看过的时刻（`AppSettings`）；Cue 在值班时带上用户给 Cue 起的名字（"等 X 回答"），
    /// 这台 Mac 上它正在出字时说"输出中"（`speaking`）。
    func shown(_ session: PiSessionState, delivery: DeliveryRequest?) -> PiShown {
        let settings = services.settings
        return PiShown(
            session, delivery: delivery, unread: settings.isUnread(session), seen: settings.sessionSeen[session.sessionID], cue: cueDuty,
            at: services.speech
        ).speaking(speaking(session))
    }

    /// 会话页顶栏的状态：只说会话自己的（你的话到哪了写在气泡下面，正在看的会话没有"有新回复"），其余同 `shown`。
    func shownInHeader(_ session: PiSessionState) -> PiShown {
        PiShown(session, cue: cueDuty).speaking(speaking(session))
    }

    /// 这台 Mac 上它此刻有正在说的话（手机上没有）。只随出字开始、结束通知，不随每个增量（`PiBridge.Slot.speaking`）。
    private func speaking(_ session: PiSessionState) -> Bool {
        #if os(macOS)
        services.pi.slot(sessionID: session.sessionID)?.speaking ?? false
        #else
        false
        #endif
    }

    /// Cue 在值班时的那一份（`PiShown` 的 `cue`）；Cue 不在值班为 nil。
    var cueDuty: CueDuty? { services.liveSessions.cue }

    func shown(_ item: PiSessionListItem) -> PiShown { shown(item.state, delivery: item.delivery) }
}

nonisolated extension PiQuestion {
    /// 只读地显示问题（只能在 Pi 里答的、或列表里的预览）：文案，下面每个选项一行。能作答的问题卡用 `options` 做成按钮。
    var displayText: String {
        ([text] + options.map { "· \($0)" }).joined(separator: "\n")
    }
}
