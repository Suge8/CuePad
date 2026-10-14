import CueStore
import CueSync
import CueText
import Foundation

/// Cue 此刻在做什么（头像的表情与环、页头的一句、菜单栏面板的一行）。在这台 Mac 值班时由管理器给出（`services.cue.state`，见 `CueWatch`）；
/// 手机与别的 Mac 上没有管理器，由库推出（`derive`）：没启用；你最近一句之后它还没说话是在想（还在路上的也算）；
/// 那一句没能送达、原因是 Mac 没有回应（`Speech`，同气泡的规则）是在睡觉。本机同步不通时说不准它在做什么，不说它在睡觉。
nonisolated enum CuePresence: Equatable, Sendable {
    /// 还没启用（Cue 页的主按钮是启用）。
    case disabled
    /// 启用了，但它住的那台 Mac 不在线。
    case asleep
    case idle
    case thinking
    /// 管理器起不来：参数是给你看的原因。
    case unreachable(String)

    /// `relay`：到 Cue 住的那台 Mac 要经过的同步（`AppServices.relay`）。
    static func derive(_ digest: CueDigest, now: Date, relay: SyncStatus?) -> CuePresence {
        guard digest.enabled else { return .disabled }
        guard let pending = digest.pendingYou else { return .idle }
        switch Speech.trip(said: pending.at, delivered: pending.deliveredAt, now: now, relay: relay) {
        case .sending, .delivered: return .thinking
        case .failed(.noReply): return .asleep
        case .failed: return .idle
        }
    }

    /// 头像变暗、闭眼：它此刻不会接话。
    var isAway: Bool {
        switch self {
        case .disabled, .asleep, .unreachable: true
        case .idle, .thinking: false
        }
    }

    var isUnreachable: Bool { if case .unreachable = self { true } else { false } }

    /// 页头、菜单栏面板那一句；空闲时不写。
    func line(name: String) -> String? {
        switch self {
        case .disabled: "\(name) 还没启用"
        case .asleep: "\(name) 在睡觉：它住的那台 Mac 好像没开"
        case .idle: nil
        case .thinking: "在想…"
        case .unreachable(let reason): reason
        }
    }
}

/// 头像的表情（`Assets` 里的 mascot-cue-*）。
nonisolated enum CueMood: String, Sendable {
    case thinking, waiting, done, sleeping, listening

    var asset: String { "mascot-cue-\(rawValue)" }

    /// 哪个表情只在这里定：睡着、起不来闭眼；在想；有等你的；你正在写（在听）；它刚报了一件做完的；平时在听。
    static func of(_ presence: CuePresence, waiting: Int, composing: Bool = false, justDone: Bool = false) -> CueMood {
        switch presence {
        case .disabled, .asleep, .unreachable: .sleeping
        case .thinking: .thinking
        case .idle: waiting > 0 ? .waiting : composing ? .listening : justDone ? .done : .listening
        }
    }
}

/// Cue 的一页摘要：名字、"等你 N"、它最近一句、你最近一句交没交出去。Mac 侧栏、iPhone 底栏、菜单栏面板、小组件都读它（一份规则）。
nonisolated struct CueDigest: Equatable, Sendable {
    var name: String
    /// 启用了（`CueProfile.activeHost` 有值）。
    var enabled: Bool
    /// 它住（或停用前住）的那台 Mac 与它的名字：绑过文件夹的 Mac 才知道名字（没启用时说去哪台启用）。
    var hostID: String?
    var hostName: String?
    /// "等你 N"（`CueWaiting.count`）。
    var waiting: Int
    /// Cue 最近对你说的那条的摘要行（第一行纯文字，Markdown 的符号去掉，`MarkdownBlock.firstPlainLine`）。
    var lastSaid: String?
    /// 它最近一句说的那件事已经做完了（头像露"做完"的表情）。
    var lastSaidDone: Bool
    /// 你最近一句之后它还没开口：那一句的时刻与交没交给它。
    var pendingYou: Pending?

    struct Pending: Equatable, Sendable {
        var at: Date
        var deliveredAt: Date?
    }

    static let empty = CueDigest(
        name: CueProfile.defaultName, enabled: false, hostID: nil, hostName: nil, waiting: 0, lastSaid: nil, lastSaidDone: false, pendingYou: nil)

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
            hostID: profile?.hostID,
            hostName: try profile?.hostID.flatMap { host in try store.directoryBindings().first { $0.hostID == host }?.hostName },
            waiting: try CueWaiting.count(in: store),
            lastSaid: said.flatMap { MarkdownBlock.firstPlainLine(CueFormat.plainText($0.text)) },
            lastSaidDone: saidTask?.status == .done,
            pendingYou: spoke ? nil : lastYou.map { Pending(at: recent[$0].createdAt, deliveredAt: recent[$0].deliveredAt) })
    }

    private static let recentWindow = 40
}

nonisolated extension CueSnapshot {
    /// 小组件那一份：表情按写快照这一刻由库推出的状态定（小组件里没有到点翻状态的计时，同步状态也不在这里，按通着算）。
    init(digest: CueDigest) {
        let mood = CueMood.of(CuePresence.derive(digest, now: .now, relay: nil), waiting: digest.waiting, justDone: digest.lastSaidDone)
        self.init(name: digest.name, waiting: digest.waiting, lastSaid: digest.lastSaid, mood: mood.rawValue)
    }
}

/// "等你 N" 只有一处算：Cue 带选项问你、还没结束的（`cueMessagesWaitingForYou`），加上不由 Cue 跟进的会话里在等你回答的
/// （Cue 跟进的会话等回答由 Cue 去答或转问你，不重复算）。
nonisolated enum CueWaiting {
    static func count(in store: isolated CueStore) throws -> Int {
        let asked = try store.cueMessagesWaitingForYou().count
        let sessions = try store.piSessionPage(.live).items.count { $0.state.waitsForYou && !$0.cueFollows }
        return asked + sessions
    }
}
