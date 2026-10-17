import CueStore
import CueText
import Foundation

/// Cue 此刻在做什么（头像的表情与环、页头的一句、Cue 页对话末尾的进展、侧栏与菜单栏面板的一行）。各端（含它值班的这台 Mac）都由库推出（`derive`）：
/// 没启用；它住的那台 Mac 不在线是在睡觉（那台的在线记录 `MacPresence`，与值班同一条，`CueStore.macOnline`；到期由订阅重读）——本机同步不通时
/// 那条记录可能只是没同步来，说不准它在不在，不说它在睡觉、照它写下的状态（值班仍按不在线算：那时它答不了会话，宁可多叫你一次）；
/// 你最近一句还在等回执是话在路上（`Speech`，与气泡同一个事实，此刻由 `SpeechClock` 给）；
/// 其余照值班的 Mac 写下的（`CueState`）：在想、在用工具是在做事，出错是起不来。
/// 在路上与在做事和 Agent 会话是同一套状态（`shown`：状态标、状态词、颜色、对话末尾那一行都一样）。
nonisolated enum CuePresence: Equatable, Sendable {
    /// 还没启用（Cue 页的主按钮是启用）。
    case disabled
    /// 启用了，但它住的那台 Mac 不在线。
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
        case .asleep: "\(name) 在睡觉：它住的那台 Mac 好像没开"
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

/// Cue 的一页摘要：名字、"等你 N"、它最近一句、你最近一句交没交出去、它此刻在做什么。Mac 侧栏、iPhone 底栏、菜单栏面板、小组件都读它（一份规则）。
nonisolated struct CueDigest: Equatable, Sendable {
    var name: String
    /// 启用了（`CueProfile.activeHost` 有值）。
    var enabled: Bool
    /// 它住（或停用前住）的那台 Mac 与它的名字：绑过文件夹的 Mac 才知道名字（没启用时说去哪台启用）。
    var hostID: String?
    var hostName: String?
    /// "等你 N"（`CueWaiting.count`）。
    var waiting: Int
    /// Cue 最近对你说的那条的摘要行：问你的是要你定什么（`CueAsk.question`，不露原话），其余是第一行纯文字（Markdown 的符号去掉，`MarkdownBlock.firstPlainLine`）。
    var lastSaid: String?
    /// 它最近一句说的那件事已经做完了（头像露"做完"的表情）。
    var lastSaidDone: Bool
    /// 它住的那台 Mac 此刻在线（`CueStore.macOnline`）；没启用为 false。
    var hostOnline: Bool
    /// 你最近一句：写下与交给它的时刻（`CueStore.cueLastYou`）；你还没说过为 nil。到哪了按此刻推（`derive`）。
    var lastYou: LastYou?
    /// 值班的 Mac 写下的此刻在做什么（`CueStore.cueState`）。
    var state: CueState?

    static let empty = CueDigest(
        name: CueProfile.defaultName, enabled: false, hostID: nil, hostName: nil, waiting: 0, lastSaid: nil, lastSaidDone: false, hostOnline: false,
        lastYou: nil, state: nil)

    struct LastYou: Equatable, Sendable {
        var said: Date
        var delivered: Date?
    }

    static func read(from store: isolated CueStore) throws -> CueDigest {
        let profile = try store.cueProfile()
        let recent = try store.cueMessages(limit: recentWindow)
        let said = recent.last { $0.author == .known(.cue) }
        let saidTask = try said?.taskID.flatMap { try store.card($0) }
        return CueDigest(
            name: profile?.name ?? CueProfile.defaultName,
            enabled: profile?.activeHost != nil,
            hostID: profile?.hostID,
            hostName: try profile?.hostID.flatMap { host in try store.directoryBindings().first { $0.hostID == host }?.hostName },
            waiting: try CueWaiting.count(in: store),
            lastSaid: said.flatMap { $0.ask?.question(task: saidTask?.heading) ?? MarkdownBlock.firstPlainLine(CueFormat.plainText($0.text)) },
            lastSaidDone: saidTask?.status == .done,
            hostOnline: try profile?.activeHost.map { try store.macOnline($0) } ?? false,
            lastYou: try store.cueLastYou().map { LastYou(said: $0.said, delivered: $0.delivered) },
            state: try store.cueState())
    }

    private static let recentWindow = 40
}

/// 一次接力（`CueWatch.flight`，`CueRelayStage` 画）：叫醒是会话 → Cue（事实是 `CueState.woke`），交给是 Cue → 会话（事实是 Cue 写的投送请求），
/// 都不另存。两种的时刻都是 Cue 那台 Mac 的时钟，在同一条时间线上比新旧。
/// 交给只飞把话或活交到会话手里的几种（`relayModes`）：说话（直接说、马上说、等它做完再说）、答它在等的问题、开新会话。
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

    static let relayModes: Set<DeliveryMode> = [.send, .steer, .followUp, .answer, .start]

    /// 一条交给：写下的时刻与交给了谁。
    struct Handed: Equatable, Sendable {
        let at: Date
        let end: RelayEnd

        init?(_ request: DeliveryRequest) {
            let session = request.target.kind == .known(.piSession) ? request.target.ref : nil
            guard session != nil || request.cardID != nil else { return nil }
            at = request.createdAt
            end = RelayEnd(session: session, task: request.cardID)
        }

        static func read(from store: isolated CueStore) throws -> [Handed] { try store.cueRequests(relayModes).compactMap(Handed.init) }
    }
}

nonisolated extension CueSnapshot {
    /// 小组件那一份：表情按写快照这一刻（`moment`）推出的状态定（快照随库与此刻重写）。
    init(digest: CueDigest, at moment: Speech.Moment) {
        let mood = CueMood.of(CuePresence.derive(digest, at: moment), waiting: digest.waiting, justDone: digest.lastSaidDone)
        self.init(name: digest.name, waiting: digest.waiting, lastSaid: digest.lastSaid, mood: mood.rawValue)
    }
}

/// "等你 N" 只有一处算：Cue 带选项问你、还没结束的（`cueMessagesWaitingForYou`），加上会话里在等你回答的
/// （`PiSessionState.asksYou`：Cue 在值班时等它回答的由它去答或转问你，不重复算；它住的那台 Mac 不在线就不算值班，回到等你）。这个数只挂在 Cue 上（Mac 与 iPad 侧栏的 Cue 一行、iPhone 的 Cue 标签、Dock 角标）：
/// Cue 是总控，一处说清"有几件在等你"；会话那一份不在 Agent 入口上另挂一个数，免得同一件事报两遍。
nonisolated enum CueWaiting {
    static func count(in store: isolated CueStore) throws -> Int {
        let asked = try store.cueMessagesWaitingForYou().count
        let onDuty = try store.cueOnDuty()
        let sessions = try store.piSessionPage(.live).items.count { $0.state.asksYou(cueOnDuty: onDuty) }
        return asked + sessions
    }
}
