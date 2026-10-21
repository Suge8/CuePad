import CueStore
import CueText
import Foundation

/// Cue 此刻在做什么（头像的表情与环、页头的一句、Cue 页对话末尾的进展、侧栏与菜单栏面板的一行）。各端（含它值班的这台 Mac）都由库推出（`derive`）：
/// 没启用；它运行的那台 Mac 不在线是在睡觉（那台的在线记录 `MacPresence`，与值班同一条，`CueStore.macOnline`；到期由订阅重读）——本机同步不通时
/// 那条记录可能只是没同步来，说不准它在不在，不说它在睡觉、照它写下的状态（值班仍按不在线算：那时它答不了会话，宁可多叫你一次）；
/// 你最近一句还在等回执是话在路上（`Speech`，与气泡同一个事实，此刻由 `SpeechClock` 给）；
/// 其余照值班的 Mac 写下的（`CueState`）：在想、在用工具是在做事，出错是起不来。
/// 在路上与在做事和 Agent 会话是同一套状态（`shown`：状态标、状态词、颜色、对话末尾那一行都一样）。
nonisolated enum CuePresence: Equatable, Sendable {
    /// 还没启用（Cue 页的主按钮是启用）。
    case disabled
    /// 启用了，但它运行的那台 Mac 不在线。
    case asleep
    case idle
    /// 你最近一句还在路上。
    case sending
    /// 在一轮里：想（`thinking`）或用工具（`tool`，`detail` 是"动作 · 目标"）。
    case working(PiWorkState, detail: String?)
    /// 管理器起不来：参数是给你看的原因。
    case unreachable(String)

    /// `moment`：此刻与到 Cue 那台 Mac 的同步从什么时候起通着（`AppServices.speech`）。
    static func derive(_ digest: CueDigest, at moment: Speech.Moment) -> CuePresence {
        guard digest.enabled else { return .disabled }
        if !digest.hostOnline && moment.reachableSince(digest.hostID) != nil { return .asleep }
        if let you = digest.lastYou, Speech.trip(said: you.said, delivered: you.delivered, host: digest.hostID, at: moment) == .sending {
            return .sending
        }
        guard let state = digest.state, let work = state.state.known else { return .idle }
        if work == .error { return .unreachable(state.detail ?? "\(digest.name) 起不来了") }
        return work.isWorking ? .working(work, detail: state.detail) : .idle
    }

    /// 头像变暗、闭眼：它此刻不会接话。
    var isAway: Bool {
        switch self {
        case .disabled, .asleep, .unreachable: true
        case .idle, .sending, .working: false
        }
    }

    var isUnreachable: Bool { if case .unreachable = self { true } else { false } }

    /// 在用工具（不是在想）：对话末尾单列正在跑的那一步。
    var isUsingTool: Bool { if case .working(.tool, _) = self { true } else { false } }

    /// 与 Agent 会话同一套的状态：话在路上、在做事；其余没有。
    var shown: PiShown? {
        switch self {
        case .sending: PiShown(status: .delivery(.inTransit(.sending)))
        case .working(let state, _): PiShown(status: .working(state))
        case .disabled, .asleep, .idle, .unreachable: nil
        }
    }

    /// 在做事时对话末尾那一行（同会话：当前动作，没有动作时是状态词）。
    var progress: String? {
        guard case .working(_, let detail) = self else { return nil }
        return detail.flatMap(PiProgress.action) ?? shown?.label
    }

    /// 它不在时那一句（页头、侧栏、菜单栏面板）；在路上、在做事写状态词（`shown`），空闲不写。
    func line(name: String) -> String? {
        switch self {
        case .disabled: "\(name) 还没启用"
        case .asleep: "\(name) 在睡觉：它运行的那台 Mac 好像没开"
        case .unreachable(let reason): reason
        case .idle, .sending, .working: nil
        }
    }
}

/// 头像的表情（`Assets` 里的 mascot-cue-*）。
nonisolated enum CueMood: String, Sendable {
    case thinking, waiting, done, sleeping, listening

    var asset: String { "mascot-cue-\(rawValue)" }

    /// 哪个表情只在这里定：睡着、起不来闭眼；在做事；话在路上（在听）；有等你的；你正在写（在听）；它刚报了一件做完的；平时在听。
    static func of(_ presence: CuePresence, waiting: Int, composing: Bool = false, justDone: Bool = false) -> CueMood {
        switch presence {
        case .disabled, .asleep, .unreachable: .sleeping
        case .working: .thinking
        case .sending: .listening
        case .idle: waiting > 0 ? .waiting : composing ? .listening : justDone ? .done : .listening
        }
    }
}

/// Cue 的一页摘要：名字、推进中与等你、它最近一句、你最近一句交没交出去、它此刻在做什么与谁叫醒的、今天做完的。
/// 三端侧栏的 Cue 一行与名片、菜单栏面板、小组件与实时活动都读它推出的 Cue 此刻（`CueNow`，一份规则）。
nonisolated struct CueDigest: Equatable, Sendable {
    var name: String
    /// 启用了（`CueProfile.activeHost` 有值）。
    var enabled: Bool
    /// 它运行（或停用前运行）的那台 Mac 与它的名字（`MacAgents.shownName`）。
    var hostID: String?
    var hostName: String?
    /// 推进中与等你（`CueStore.cueTally`）。
    var tally: CueTally
    /// "等你 M"。
    var waiting: Int { tally.waiting.count }
    /// 推进中几件。
    var advancing: Int { tally.advancing.count }
    /// 新消息有几条（`CueStore.cueUnread`）。
    var unread: Int
    /// Cue 最近对你说的那条的摘要行（`CueMessage.headline`），只给 Mac 侧栏名片的气泡（Cue 那一行写 Cue 此刻，不写它）。
    /// 结束了的提问（`CueQuestionEnd`）不算：那件事已经定了，接着写它在那之前最近说的。
    var lastSaid: String?
    /// 它最近一句说的那件事已经做完了（头像露"做完"的表情）。
    var lastSaidDone: Bool
    /// 它运行的那台 Mac 此刻在线（`CueStore.macOnline`）；没启用为 false。
    var hostOnline: Bool
    /// 你最近一句：写下与交给它的时刻（`CueStore.cueLastYou`）；你还没说过为 nil。到哪了按此刻推（`derive`）。
    var lastYou: LastYou?
    /// 值班的 Mac 写下的此刻在做什么（`CueStore.cueState`）。
    var state: CueState?
    /// 在跑的这一轮为什么醒（`CueStore.cueWaking`）：醒的时刻与"被谁叫醒"那一截；歇着、这一轮没记为 nil。
    var woke: Woke?
    /// 今天做完的顶层任务（被等你占着的不算，同任务看板的做完列），最近的在前。
    var done: [Card]

    static let empty = CueDigest(
        name: CueProfile.defaultName, enabled: false, hostID: nil, hostName: nil, tally: .empty, unread: 0, lastSaid: nil, lastSaidDone: false, hostOnline: false,
        lastYou: nil, state: nil, woke: nil, done: [])

    struct Woke: Equatable, Sendable {
        var at: Date
        var text: String?
    }

    struct LastYou: Equatable, Sendable {
        var said: Date
        var delivered: Date?
    }

    static func read(from store: isolated CueStore) throws -> CueDigest {
        let profile = try store.cueProfile()
        let recent = try store.cueMessages(limit: recentWindow)
        let said = recent.last { $0.author == .known(.cue) && ($0.choices == nil || $0.answeredAt == nil) }
        let saidTask = try said?.taskID.flatMap { try store.card($0) }
        let tally = try store.cueTally()
        return CueDigest(
            name: profile?.name ?? CueProfile.defaultName,
            enabled: profile?.activeHost != nil,
            hostID: profile?.hostID,
            hostName: try profile?.hostID.map { try store.macAgents(on: $0).shownName },
            tally: tally,
            unread: try store.cueUnread().count,
            lastSaid: said?.headline,
            lastSaidDone: saidTask?.status == .done,
            hostOnline: try profile?.activeHost.map { try store.macOnline($0) } ?? false,
            lastYou: try store.cueLastYou().map { LastYou(said: $0.said, delivered: $0.delivered) },
            state: try store.cueState(),
            woke: try store.cueWaking().map { Woke(at: $0.at, text: try Self.woke($0.wake, store: store)) },
            done: tally.free(try store.tasksDone(since: Calendar.current.startOfDay(for: .now))))
    }

    /// 这一轮为什么醒，写成那一句的开头（"被 canvas-zoom 叫醒"）；换上下文、改设置这类内部的事不说，按在想写。
    private static func woke(_ wake: CueWake, store: isolated CueStore) throws -> String? {
        switch wake {
        case .message: return "在回你的话"
        case .idle: return "例行查看"
        case .tidy: return "在整理记忆"
        case .reminder: return "提醒到点"
        case .enabled: return "刚启用"
        case .renewed, .settingsChanged: return nil
        case .sessionActivity(let stirs):
            var seen = Set<String>()
            let ids = stirs.compactMap(\.session).filter { seen.insert($0).inserted }
            guard let first = ids.first else { return "有一件做完了" }
            let title = try store.piSessions(sessionIDs: [first])[first]?.state.title
            let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? "会话"
            return ids.count > 1 ? "被 \(name) 等 \(ids.count) 处叫醒" : "被 \(name) 叫醒"
        }
    }

    private static let recentWindow = 40

    /// 头像此刻的表情（不算你正在写）：Cue 那一行、小组件与实时活动同一个。
    func mood(at moment: Speech.Moment) -> CueMood {
        CueMood.of(CuePresence.derive(self, at: moment), waiting: waiting, justDone: lastSaidDone)
    }
}

nonisolated extension CueMessage {
    /// Cue 的一句在对话以外的那一行（Mac 侧栏名片的气泡、"等你"卡与全屏预览底栏的第一句、回答的引用、实时活动里第一件等你）：提问是要你定什么（`CueAsking.question`，不露原话），
    /// 其余是第一行纯文字（Markdown 的符号去掉，`MarkdownBlock.firstPlainLine`）。
    var headline: String? { asking?.question ?? MarkdownBlock.firstPlainLine(CueFormat.plainText(text)) }
}

/// 一次接力（`LiveSessions.flight`，`CueRelayStage` 画）：叫醒是会话 → Cue（事实是在跑那一轮为什么醒，`CueStore.cueWaking`），交给是 Cue → 会话（事实是 Cue 写的投送请求），
/// 都不另存。时刻在同一条时间线上比新旧：叫醒与说话是 Cue 那台 Mac 的时钟，开新会话是开出它的那台（多数就是 Cue 那台）。
/// 交给只飞把话或活交到会话手里的几种：说话、答它在等的问题（`spoken`，写下请求的时刻），开新会话（开出的会话有了记录的时刻，`CueStore.cueOpenedSessions`：
/// 写下请求时会话还不在，等它出现才飞到它那一行）。
/// 不飞的：停下与结束是把活收回来，结束还常在做完一件事时一次结束好几个（`endUnusedSessions`），一片光讲不清；
/// 换模型与思考强度（config）总跟在一句话前面，那句话飞就够了。
nonisolated struct CueFlight: Equatable, Sendable {
    enum Direction: Sendable {
        /// 会话 → Cue
        case wake
        /// Cue → 会话
        case relay
    }

    let direction: Direction
    /// 这一次的时刻：变成新的就又播一次。
    let at: Date
    /// 接力的那几个会话，最新的在前。
    let ends: [RelayEnd]

    private static let spoken: Set<DeliveryMode> = [.send, .answer]

    /// 一条交给：发生的时刻与交给了谁。
    struct Handed: Equatable, Sendable {
        let at: Date
        let end: RelayEnd

        static func read(from store: isolated CueStore) throws -> [Handed] {
            let said = try store.cueRequests(spoken).compactMap { request in
                request.target.ref.map { Handed(at: request.createdAt, end: RelayEnd(session: $0, task: request.cardID)) }
            }
            let opened = try store.cueOpenedSessions().map { Handed(at: $0.at, end: RelayEnd(session: $0.session, task: $0.card, opens: true)) }
            return said + opened
        }
    }

    /// 接力读的事实：叫醒它的那一下与它交给的那几条。
    struct Facts: Equatable, Sendable {
        /// 在跑的这一轮是会话的动静叫醒的：醒的时刻与叫醒它的那几个会话
        var woke: (at: Date, sessions: [String])?
        var handed: [Handed]

        static func read(from store: isolated CueStore) throws -> Facts {
            var woke: (at: Date, sessions: [String])?
            if let waking = try store.cueWaking(), case .sessionActivity(let stirs) = waking.wake {
                var seen = Set<String>()
                woke = (waking.at, stirs.compactMap(\.session).filter { seen.insert($0).inserted })
            }
            return Facts(woke: woke, handed: try Handed.read(from: store))
        }

        static func == (a: Self, b: Self) -> Bool { a.woke?.at == b.woke?.at && a.woke?.sessions == b.woke?.sessions && a.handed == b.handed }

        /// 比 `seen` 新的那一次接力；没有为 nil。同一次读到两种都新时取更新的那种。
        func flight(after seen: Date?) -> CueFlight? {
            let since = seen ?? .distantPast
            let woke = woke.flatMap { $0.at > since ? CueFlight(direction: .wake, at: $0.at, ends: $0.sessions.map { RelayEnd(session: $0) }) : nil }
            let fresh = handed.filter { $0.at > since }.sorted { $0.at > $1.at }
            let relay = fresh.first.map { CueFlight(direction: .relay, at: $0.at, ends: fresh.map(\.end)) }
            return [woke, relay].compactMap { $0 }.max { $0.at < $1.at }
        }

        /// 读到的最新时刻。
        var latest: Date? { ([woke?.at] + handed.map(\.at)).compactMap { $0 }.max() }
    }
}


