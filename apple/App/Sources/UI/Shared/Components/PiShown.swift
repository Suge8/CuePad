import CueStore
import Foundation

nonisolated extension PiSessionListItem {
    /// 没能送达的话有几句，按 Pi 的会话 id（只留有的）：手里只有会话记录的行（Mac 侧栏、菜单栏、⌘K、项目页 Agent 栏）按它找自己的数。
    static func undelivered(_ items: [PiSessionListItem]) -> [String: Int] {
        Dictionary(items.filter { $0.undelivered > 0 }.map { ($0.state.sessionID, $0.undelivered) }) { first, _ in first }
    }
}

nonisolated extension PiSessionState {
    /// 会话列表的顺序（Agent 页、Mac 侧栏）：要你注意的在前（`PiShown.rank`），同一档保持原来的先后（最近进入当前状态的在前）。
    /// `deliveries` 是发给各会话（按 Pi 的会话 id）的最近一条投送请求：话在路上的与工作中同档，发出那一刻就挪到位。
    /// 不看有没有新回复：看一眼就让行换位置，列表会在手下跳。
    /// `cueOnDuty`：Cue 在值班（`LiveSessions.cueOnDuty`），等它回答的与在跑的同档（`PiShown.Status.cueAsking`）。
    static func inListOrder(_ sessions: [PiSessionState], deliveries: [String: DeliveryRequest] = [:], cueOnDuty: Bool = false) -> [PiSessionState] {
        sessions.enumerated()
            .map { index, session in
                // 排序只看档位，不读说法：Cue 的名字给空串
                let shown = PiShown(session, delivery: deliveries[session.sessionID], cue: cueOnDuty ? "" : nil)
                return (rank: shown.rank, offset: index, session: session)
            }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.session)
    }

    /// 在处理中（思考、输出、运行工具、子代理）。
    var isWorking: Bool { state.isWorking }

    /// 说过话：对话里有过一轮（做完的或进行中的）。终端里刚开、还没说过话的会话没有，它停在空闲不是"该你了"。
    var hasStarted: Bool { lastPrompt != nil || lastReply != nil || pendingPrompt != nil }
}

/// 发给会话、还没被它的状态吸收的那条投送请求此刻在哪一步。会话状态只来自 Mac 同步回来的记录，发出后要等 Mac 执行、写回、
/// 再同步过来才变；投送请求是本机当场写出的，所以显示状态把它算进去：发出即"发送中"，会话进入处理中后让位给会话状态。
nonisolated enum PiDelivery: Hashable, Sendable {
    /// 写出了，Mac 还没接手。
    case sending
    /// Mac 正在送达。
    case delivering
    /// 发给已结束的会话：Mac 先在后台唤醒它。
    case waking
    /// 送到了，会话状态还没跟上。
    case delivered
    case failed

    /// 还没送到的话此刻怎么说（会话行的小标记、会话页气泡下面同一套）：会话在跑时"等它做完再说"的话是"排队中"，
    /// 其余 Mac 还没接手是"发送中"、接手了是"送达中"。
    static func transit(_ request: DeliveryRequest, busy: Bool) -> String {
        if busy, request.mode == .known(.followUp) { return "排队中" }
        return request.status == .known(.pending) ? "发送中" : "送达中"
    }

    /// `request` 是发给 `session` 的最近一条（`DeliveryMode.toSession` 的方式）。会话状态的时间（`stateSince`）与送达时间
    /// （`completedAt`）都是 Mac 的钟；发出时间是发起设备的钟，只拿来判断"发出之后会话动起来了"，跨设备的钟差最多让"发送中"早一点让位。
    /// 送到了的请求过一会儿就被执行它的 Mac 清理，"已送达"不会一直挂着；没能送达的留着（等你重发或移除），
    /// 在你看过这个会话（`seen`，本机最后一次看它）之前一直显示，会话之后动过也不算数。
    static func phase(of request: DeliveryRequest?, for session: PiSessionState, seen: Date? = nil) -> PiDelivery? {
        guard let request, let mode = request.mode.known, DeliveryMode.toSession.contains(mode) else { return nil }
        let ended = session.state == .known(.ended)
        switch request.status.known {
        case .pending, .executing:
            // 发出之后才进入处理中，才算它在处理这句话；时间存到毫秒，同刻算作发出前就在跑（这句还在排队）
            if session.isWorking && session.stateSince > request.createdAt { return nil }
            if ended { return .waking }
            return request.status == .known(.pending) ? .sending : .delivering
        case .succeeded:
            // 等会话状态跟上（进入处理中，或在送达之后变过）就让位
            let caughtUp = session.isWorking || session.stateSince > (request.completedAt ?? request.createdAt)
            return caughtUp ? nil : .delivered
        case .failed:
            return (seen ?? .distantPast) > (request.completedAt ?? request.modifiedAt) ? nil : .failed
        case nil:
            return nil
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
/// Cue 在值班（`CueProfile.onDuty`）时这时该看的是 Cue，只说"歇着"；会话等的回答 CuePad 答得了时等的也是 Cue
/// （"等 Cue 回答"，中性墨色，`PiSessionState.waitsForCue`），赭黄只留给在等你的（与"等你 N"同一条规则，`CueWaiting`）。计时读哪一种（`clock`）也在这里定。
nonisolated struct PiShown: Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case delivery(PiDelivery)
        /// 思考、输出、运行工具、等子代理、压缩上下文。
        case working(PiWorkState)
        case asking
        /// 在等回答，等的是 Cue（`PiSessionState.waitsForCue`），不是你。
        case cueAsking
        case failed
        /// 在线，但它加载的扩展与这台 Mac 上的 CuePad 不同，要在终端里 /reload。
        case restart
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
    /// 会话在跑时还在路上的话："你的话排队中"（等这一轮做完再送）、"你的话发送中"。
    var note: String?
    /// 计时；只有状态、没有会话的（子代理、样板）没有。
    var clock: PiClock?
    /// 值班的 Cue 的名字（用户起的）；Cue 不在值班为 nil。
    var cue: String?
}

nonisolated extension PiShown {
    /// `cue`：值班的 Cue 的名字（Cue 在值班时给，见 `Workspace.shown`）。
    init(_ session: PiSessionState, delivery: DeliveryRequest? = nil, unread: Bool = false, seen: Date? = nil, cue: String? = nil) {
        let onDuty = cue != nil
        let own = PiClock.reading(session.state, stateSince: session.stateSince, busySince: session.busySince)
        let busy = session.isWorking || session.state == .known(.waitingForUser)
        let reported = Self.status(of: session.state)
        let asked = session.waitsForCue(cueOnDuty: onDuty) ? Status.cueAsking : reported
        switch PiDelivery.phase(of: delivery, for: session, seen: seen) {
        case .failed:
            self.init(status: .delivery(.failed), clock: own, cue: cue)
        case let phase? where busy:
            let transit = delivery.map { PiDelivery.transit($0, busy: true) }
            self.init(status: asked, note: phase == .delivered ? nil : transit.map { "你的话\($0)" }, clock: own, cue: cue)
        case let phase?:
            self.init(status: .delivery(phase), clock: delivery.map { .sent(since: $0.createdAt) }, cue: cue)
        case nil where session.state == .known(.settled):
            self.init(status: !session.hasStarted ? .fresh : onDuty ? .resting : unread ? .unread : .idle, clock: own, cue: cue)
        case nil:
            self.init(status: asked, clock: own, cue: cue)
        }
    }

    /// 只有 Pi 报的状态（子代理、样板）：空闲按看过处理。
    init(state: Open<PiWorkState>) { status = Self.status(of: state) }

    private static func status(of state: Open<PiWorkState>) -> Status {
        switch state.known {
        case .thinking, .outputting, .tool, .delegating, .compacting: .working(state.known!)
        case .waitingForUser: .asking
        case .error: .failed
        case .incompatible: .restart
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
        case .delivery(.sending): "发送中"
        case .delivery(.delivering): "送达中"
        case .delivery(.waking): "正在唤醒"
        case .delivery(.delivered): "已送达"
        case .delivery(.failed): "没能送达"
        case .working(.outputting): "输出中"
        case .working(.tool): "运行工具"
        case .working(.delegating): "子代理工作中"
        case .working(.compacting): "正在压缩上下文"
        case .working: "思考中"
        case .asking: "等你确认"
        case .cueAsking: "等 \(cue ?? "") 回答"
        case .failed: "出错"
        case .restart: "在线，需要 /reload"
        case .unread: "有新回复"
        case .idle: "该你了"
        case .resting: "歇着"
        case .fresh: "新会话"
        case .ended: "已结束"
        case .interrupted: "被打断"
        case .unknown: "未知状态"
        }
    }

    /// 会话页顶上点玻璃标题弹出的一句说明：只有需要 /reload（旧版扩展）时有——怎么接上。命令中间不许折行（"/" 后接词连接符）。
    var explanation: String? {
        status == .restart ? "这个会话还在用升级前的旧版扩展，CuePad 看不到它的进展、也发不进去。在终端里对这个会话执行 /\u{2060}reload 就能接上。" : nil
    }

    /// 只有一个状态标时它说的是什么（读屏标签、悬停提示、项目长按菜单的标题、任务上的会话状态）。
    var presence: String {
        switch status {
        case .delivery(.waking): "正在唤醒 Agent"
        case .delivery(.failed): "没能送达 Agent"
        case .delivery: "正在发给 Agent"
        case .working(.compacting): "Agent 正在压缩上下文"
        case .working: "Agent 正在工作"
        case .asking: "Agent 等你确认"
        case .cueAsking: "Agent 在等 \(cue ?? "") 回答"
        case .failed: "Agent 出错"
        case .restart: "Agent 在线，需要在终端里 /reload"
        case .unread: "Agent 有新回复"
        case .idle: "Agent 在等你说下一句"
        case .resting: "Agent 歇着"
        case .fresh: "Agent 新会话"
        case .ended: "Agent 会话已结束"
        case .interrupted: "Agent 被打断"
        case .unknown: "Agent 状态未知"
        }
    }

    /// 名字与状态词加粗：做完了你还没看。
    var isUnread: Bool { status == .unread }

    /// 此刻显示为没能送达时就是那条请求（`request` 是算这个状态用的那条），Mac 任务面板据此写原因（`PiProgress.note`）。
    func undelivered(_ request: DeliveryRequest?) -> DeliveryRequest? { status == .delivery(.failed) ? request : nil }

    /// 在动：工作中（心电线）、话在路上（三层上箭头）。
    var isLive: Bool {
        switch status {
        case .working, .delivery(.sending), .delivery(.delivering), .delivery(.waking), .delivery(.delivered): true
        default: false
        }
    }

    /// 会话列表的档：等你确认 → 出错与没能送达 → 工作中与话在路上 → 停下的 → 已结束。
    var rank: Int {
        switch status {
        case .asking: 0
        case .failed, .delivery(.failed): 1
        case .working, .delivery, .cueAsking: 2
        // 旧扩展的会话要 /reload 是可以晚点做的维护，不压在在跑的会话上面
        case .restart: 3
        case .unread, .idle, .resting, .fresh, .interrupted, .unknown: 4
        case .ended: 5
        }
    }

    /// 选会话时排在前面的（发给 Agent 的会话选单）：等你确认 → 出错 → 有新回复 → 工作中 → 需要 /reload → 停下的 → 已结束。
    var urgency: Int {
        switch status {
        case .asking: 6
        case .failed, .delivery(.failed): 5
        case .unread: 4
        case .working, .delivery, .cueAsking: 3
        case .restart: 2
        case .idle, .resting, .fresh, .interrupted, .unknown: 1
        case .ended: 0
        }
    }
}

nonisolated extension PiShown {
    /// 要你动手：等你确认、出错、没能送达。只有它们带彩色（需要 /reload 是维护，次要墨色）。
    var needsYou: Bool {
        switch status {
        case .asking, .failed, .delivery(.failed): true
        default: false
        }
    }
}

extension AppSettings {
    /// 这个会话在本机界面上显示的状态；`delivery` 是发给它的最近一条投送请求（`PiSessionListItem.delivery`）。
    /// `cue`：值班的 Cue 的名字（不在值班为 nil）；界面经 `Workspace.shown` 调，名字从那里来。
    func shown(_ session: PiSessionState, delivery: DeliveryRequest?, cue: String? = nil) -> PiShown {
        PiShown(session, delivery: delivery, unread: isUnread(session), seen: sessionSeen[session.sessionID], cue: cue)
    }
}

extension Workspace {
    /// 这个会话在本机界面上显示的状态（`AppSettings.shown`）：Cue 在值班时带上用户给 Cue 起的名字（"等 X 回答"）。
    func shown(_ session: PiSessionState, delivery: DeliveryRequest?) -> PiShown {
        services.settings.shown(session, delivery: delivery, cue: cueOnDuty)
    }

    /// 值班的 Cue 的名字（`PiShown` 的 `cue`）；Cue 不在值班为 nil。
    var cueOnDuty: String? { services.liveSessions.cueOnDuty ? cue.name : nil }

    func shown(_ item: PiSessionListItem) -> PiShown { shown(item.state, delivery: item.delivery) }
}

nonisolated extension PiQuestion {
    /// 只读地显示问题（只能在 Pi 里答的、或列表里的预览）：文案，下面每个选项一行。能作答的问题卡用 `options` 做成按钮。
    var displayText: String {
        ([text] + options.map { "· \($0)" }).joined(separator: "\n")
    }
}

nonisolated extension PiAnswerValue {
    /// 答了什么，一句话："覆盖"、"是"。
    var label: String {
        switch self {
        case .option(let option): option
        case .confirmed(let confirmed): confirmed ? "是" : "否"
        case .text(let text): text
        }
    }
}
