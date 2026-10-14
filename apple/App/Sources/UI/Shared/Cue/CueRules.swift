import CueStore
import CueText
import Foundation

/// Cue 此刻在做什么（头像的表情与环、页头的一句、Cue 页对话末尾的进展、侧栏与菜单栏面板的一行）。各端（含它值班的这台 Mac）都由库推出（`derive`）：
/// 没启用；你最近一句还没交给它：不到 `undeliveredGrace` 是话在路上，超过是在睡觉（它住的那台 Mac 多半没开）；
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

    /// 你的话多久没交给 Cue 就算它住的那台 Mac 不在线。
    static let undeliveredGrace: TimeInterval = 30

    static func derive(_ digest: CueDigest, overdue: Bool) -> CuePresence {
        guard digest.enabled else { return .disabled }
        if let pending = digest.pendingYou, !pending.delivered { return overdue ? .asleep : .sending }
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

    /// 与 Agent 会话同一套的状态：话在路上、在做事；其余没有。
    var shown: PiShown? {
        switch self {
        case .sending: PiShown(status: .delivery(.sending))
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
    /// 它住（或停用前住）的那台 Mac 的名字：绑过文件夹的 Mac 才知道名字（没启用时说去哪台启用）。
    var hostName: String?
    /// "等你 N"（`CueWaiting.count`）。
    var waiting: Int
    /// Cue 最近对你说的那条的摘要行（第一行纯文字，Markdown 的符号去掉，`MarkdownBlock.firstPlainLine`）。
    var lastSaid: String?
    /// 它最近一句说的那件事已经做完了（头像露"做完"的表情）。
    var lastSaidDone: Bool
    /// 你最近一句之后它还没开口：那一句的时刻与交没交给它。
    var pendingYou: Pending?
    /// 值班的 Mac 写下的此刻在做什么（`CueStore.cueState`）。
    var state: CueState?

    struct Pending: Equatable, Sendable {
        var at: Date
        var delivered: Bool
    }

    static let empty = CueDigest(name: CueProfile.defaultName, enabled: false, hostName: nil, waiting: 0, lastSaid: nil, lastSaidDone: false, pendingYou: nil, state: nil)

    static func read(from store: isolated CueStore) throws -> CueDigest {
        let profile = try store.cueProfile()
        let recent = try store.cueMessages(limit: recentWindow)
        let lastYou = recent.lastIndex { $0.author == .known(.you) }
        let spoke = lastYou.map { index in recent[(index + 1)...].contains { [.known(.cue), .known(.note)].contains($0.author) } } ?? true
        let said = recent.last { $0.author == .known(.cue) }
        let saidTask = try said?.taskID.flatMap { try store.card($0) }
        return CueDigest(
            name: profile?.name ?? CueProfile.defaultName,
            enabled: profile?.activeHost != nil,
            hostName: try profile?.hostID.flatMap { host in try store.directoryBindings().first { $0.hostID == host }?.hostName },
            waiting: try CueWaiting.count(in: store),
            lastSaid: said.flatMap { MarkdownBlock.firstPlainLine(CueFormat.plainText($0.text)) },
            lastSaidDone: saidTask?.status == .done,
            pendingYou: spoke ? nil : lastYou.map { Pending(at: recent[$0].createdAt, delivered: recent[$0].deliveredAt != nil) },
            state: try store.cueState())
    }

    private static let recentWindow = 40
}

nonisolated extension CueSnapshot {
    /// 小组件那一份：表情按库推出的状态定（小组件里没有"交不出去满 30 秒"的计时，按没超时算）。
    init(digest: CueDigest) {
        let mood = CueMood.of(CuePresence.derive(digest, overdue: false), waiting: digest.waiting, justDone: digest.lastSaidDone)
        self.init(name: digest.name, waiting: digest.waiting, lastSaid: digest.lastSaid, mood: mood.rawValue)
    }
}

/// "等你 N" 只有一处算：Cue 带选项问你、还没结束的（`cueMessagesWaitingForYou`），加上不由 Cue 跟进的会话里在等你回答的
/// （Cue 跟进的会话等回答由 Cue 去答或转问你，不重复算）。
nonisolated enum CueWaiting {
    static func count(in store: isolated CueStore) throws -> Int {
        let asked = try store.cueMessagesWaitingForYou().count
        let sessions = try store.piSessionPage(.live).items.count(where: \.asksYou)
        return asked + sessions
    }
}
