import CueStore
import CueText
import Foundation

/// Cue 此刻在做什么（头像的表情与环、页头的一句、菜单栏面板的一行）。Cue 住在这台 Mac 上时就是管理器的状态（`services.cue.state`，见 `CueWatch`）；
/// 手机与别的 Mac 上没有管理器，由库推出（`derive`）：
/// 没启用是睡着；你最近一句已交给它、之后它还没说话是在想；没交出去超过 `undeliveredGrace` 是起不来（它住的那台 Mac 多半没开）。
nonisolated enum CuePresence: Equatable, Sendable {
    case asleep
    case idle
    case thinking
    /// 起不来：参数是给你看的原因。
    case unreachable(String)

    /// 你的话多久没交给 Cue 就算它没在。
    static let undeliveredGrace: TimeInterval = 30
    static let offline = "Cue 住在那台 Mac 上，它好像没开"

    static func derive(_ digest: CueDigest, overdue: Bool) -> CuePresence {
        guard digest.enabled else { return .asleep }
        guard let pending = digest.pendingYou else { return .idle }
        if pending.delivered { return .thinking }
        return overdue ? .unreachable(offline) : .thinking
    }

    #if os(macOS)
    init(_ state: CueState) {
        switch state {
        case .asleep: self = .asleep
        case .idle: self = .idle
        case .thinking: self = .thinking
        case .failed(let reason): self = .unreachable(reason)
        }
    }
    #endif

    /// 页头、菜单栏面板那一句；空闲时不写。
    func line(name: String) -> String? {
        switch self {
        case .asleep: "\(name) 在睡觉"
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
        case .asleep, .unreachable: .sleeping
        case .thinking: .thinking
        case .idle: waiting > 0 ? .waiting : composing ? .listening : justDone ? .done : .listening
        }
    }
}

/// Cue 的一页摘要：名字、"等你 N"、它最近一句、你最近一句交没交出去。Mac 侧栏、iPhone 底栏、菜单栏面板、小组件都读它（一份规则）。
nonisolated struct CueDigest: Equatable, Sendable {
    var name: String
    var enabled: Bool
    /// 住在哪台 Mac。
    var hostID: String?
    /// "等你 N"（`CueWaiting.count`）。
    var waiting: Int
    /// Cue 最近对你说的一句（纯文字）。
    var lastSaid: String?
    /// 它最近一句说的那件事已经做完了（头像露"做完"的表情）。
    var lastSaidDone: Bool
    /// 你最近一句之后它还没开口：那一句的时刻与交没交给它。
    var pendingYou: Pending?

    struct Pending: Equatable, Sendable {
        var at: Date
        var delivered: Bool
    }

    static let empty = CueDigest(name: CueProfile.defaultName, enabled: false, hostID: nil, waiting: 0, lastSaid: nil, lastSaidDone: false, pendingYou: nil)

    static func read(from store: isolated CueStore) throws -> CueDigest {
        let profile = try store.cueProfile()
        let recent = try store.cueMessages(limit: recentWindow)
        let lastYou = recent.lastIndex { $0.author == .known(.you) }
        let spoke = lastYou.map { index in recent[(index + 1)...].contains { [.known(.cue), .known(.note)].contains($0.author) } } ?? true
        let said = recent.last { $0.author == .known(.cue) }
        let saidTask = try said?.taskID.flatMap { try store.card($0) }
        return CueDigest(
            name: profile?.name ?? CueProfile.defaultName,
            enabled: profile?.enabledAt != nil && profile?.hostID != nil, hostID: profile?.hostID,
            waiting: try CueWaiting.count(in: store),
            lastSaid: said.map { CueFormat.plainText($0.text) },
            lastSaidDone: saidTask?.status == .done,
            pendingYou: spoke ? nil : lastYou.map { Pending(at: recent[$0].createdAt, delivered: recent[$0].deliveredAt != nil) })
    }

    private static let recentWindow = 40
}

nonisolated extension CueSnapshot {
    /// 小组件那一份：表情按库推出的状态定（小组件里没有"交不出去满 30 秒"的计时，按没超时算）。
    init(digest: CueDigest) {
        let mood = CueMood.of(CuePresence.derive(digest, overdue: false), waiting: digest.waiting, justDone: digest.lastSaidDone)
        self.init(name: digest.name, waiting: digest.waiting, lastSaid: digest.lastSaid?.firstLine, mood: mood.rawValue)
    }
}

/// "等你 N" 只有一处算：Cue 带选项问你、还没答的，加上不由 Cue 跟进的会话里在等你回答的
/// （Cue 跟进的会话等回答由 Cue 去答或转问你，不重复算）。
nonisolated enum CueWaiting {
    static func count(in store: isolated CueStore) throws -> Int {
        let asked = try store.cueMessagesWaitingForYou().count
        var sessions = 0
        for item in try store.piSessionPage(.live).items where item.state.waitsForYou {
            if try !followed(item.state.sessionID, in: store) { sessions += 1 }
        }
        return asked + sessions
    }

    /// 会话绑着的任务由 Cue 跟进。
    static func followed(_ sessionID: String, in store: isolated CueStore) throws -> Bool {
        guard let leaf = try store.task(boundTo: sessionID) else { return false }
        return try store.card(try store.topTask(of: leaf.id))?.cueFollows ?? false
    }
}
