import Foundation

/// Cue 此刻（WORDS.md「推进中」「等你」）：各端 Cue 那一行、小组件、灵动岛与锁屏、App 图标与菜单栏图标的角标读的唯一一份。
/// 这里是推出来的这一份怎么画、随时间怎么变，各处只画（`CueNowViews`）。从库推出在 App 的 Services（`CueNow.init(_:at:local:)`，从 Cue 的摘要 `CueDigest`）；
/// 推进中、被等你占着哪件与 Agent 数的规则只在 Kit（`CueTally`、`CueAgents`），这里与 App 都不另算。
/// - 头像是哪一拍（`beat`）由 Cue 自己（`cue`）与下面几样推出，各处的头像只读它。
/// - 数字账（`ledger`）：推进中那项只在有件在跑或等子代理交回时写（`Tally.moving`），都歇着时写那一句（`quietLine`）；每件此刻的样子不进数字账。
///   按件分"3 在跑 1 等子代理"看不出规模，加起来又不数歇着的、对不上推进中，所以数字账仍数任务。
/// - 灵动岛常驻只取一个数：有等你就取 `needsYou`，否则取活跃 Agent 总数 `agentCount`；它不等于推进中任务数。
/// - 角标（`needsYou`）：App 图标、菜单栏图标与灵动岛最小态同一个数。
/// - 快的事实（Cue 在想、话在路上）几分钟就变，后台的岛不一定等得到下一份：过了 `staleAt` 只信慢的（`settled`）。
/// 刚做完的那件只留 `doneWindow`：到点由读的一方按时刻收掉（`aged(to:)`、`nextChange(after:)`），不另计时；
/// 推出之后自己不会再收到新一份的（小组件、实时活动）按 `shown(at:)` 画、在 `nextShownChange(after:)` 那一刻让系统重画。
nonisolated struct CueNow: Codable, Hashable, Sendable {
    var name: String
    var cue: Brain
    /// 截掉之前各种各几件：数字账与角标数的是它，不是列得下的那几行。
    var tally: Tally
    var advancing: Int
    var subagents: Int
    /// 至多 `itemLimit` 件；截的时候留住最近刚做完的那件（`justDone`，头像那一拍与那一句读它）。
    var items: [Item]
    /// 第一件等你：说什么、"打开"去哪，只有 Cue 带选项的提问能"允许一次"（会话在问的只给打开）。
    var first: Wait?
    var at: Date
    /// Mac 上它运行在别的 Mac 时那一句（"在「Mac Studio」上运行"）；这台或手机上为 nil。
    var elsewhere: String? = nil
    var decay: [Decay] = []
    var unconfirmed = false
    var cueUntil: Date? = nil
    /// 参与工作的 Agent 总数；还没从库推出过（`empty`）时未知。
    var agentCount: Int? = nil

    enum CodingKeys: String, CodingKey {
        case name, cue, tally, advancing, subagents, items, first, at, elsewhere, agentCount
        case decay = "x", unconfirmed = "u", cueUntil = "v"
    }

    enum Brain: Codable, Hashable, Sendable {
        /// 此刻不会接话：那一句原因（"「Mac Studio」没开"、换新 Mac 时"正在从 iCloud 同步…"），起不来时 `failed`。
        case away(String, failed: Bool)
        case idle
        case hearing
        /// `woke`：谁叫醒的（"被 canvas-zoom 叫醒"那一截），不知道为 nil。
        case working(woke: String?, doing: String?, since: Date)
    }

    struct Tally: Codable, Hashable, Sendable {
        var asks = 0
        var reply = 0
        /// 推进中在跑或等子代理交回的（不数歇着的）：有它才写"N 推进中"、开着实时活动。
        var moving = 0
        /// 其中歇着、等它派出去的子代理交回的（`Item.Kind.delegating`）：头像那一拍读它（每件一行截过，读不全）。
        var delegating = 0

        enum CodingKeys: String, CodingKey { case asks, reply, moving, delegating }

        /// "等你 N"：拍板加待回复，这条规则只在这里（`CueNow.needsYou`）。
        var needsYou: Int { asks + reply }
    }

    struct Item: Codable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case asks
            /// 待回复：Cue 留给你回的会话（墨色，赭黄只给拍板）
            case reply
            case running
            case delegating
            case resting
            case unconfirmed
            case done
        }

        /// 那一份活的 id（`CueWork.id`、`CueTally.Wait.id`，待回复的是 "reply/会话 id"，刚做完的是 "done/任务 id"）。
        var id: String
        var kind: Kind
        var name: String
        var since: Date
        var subagents: Int
        var slot = 0
        /// 状态未确认是因为它的会话所在的那台 Mac 没开：那台的名字（`RuntimeTimeline.Work.offline`），这一行写"「那台」没开"（`label`）。
        var offline: String? = nil

        enum CodingKeys: String, CodingKey { case id, kind, name, since, subagents
            case slot = "p", offline = "o" }

        var label: String { offline.map { String(localized: "「\($0)」没开") } ?? kind.label }

        var expiry: Date? { kind == .done ? since.addingTimeInterval(CueNow.doneWindow) : nil }

        func isFresh(at date: Date) -> Bool { expiry.map { $0 > date } ?? true }
    }

    struct Wait: Codable, Hashable, Sendable {
        var title: String
        var detail: String?
        var open: URL
        var allow: Allow?
    }

    /// "允许一次"答哪条提问、选哪一项（提问的第一项，`CueAsk.once`）。
    struct Allow: Codable, Hashable, Sendable {
        var message: UUID
        var choice: String
    }

    static let itemLimit = 8
    static let doneWindow: TimeInterval = 10 * 60
    /// 一份写下后多久算过时：在一轮里、话在路上这类快的事实几分钟就变，其余慢。
    static let fastStale: TimeInterval = 3 * 60
    static let slowStale: TimeInterval = 15 * 60
    static let quiet = String(localized: "手上没有事")
    /// 在一轮里、没在用工具也不知道谁叫醒的那一句：同会话与对话末尾的状态词（`SessionShown` 的 working）。
    static let thinking = String(localized: "思考中")

    var justDone: Item? { items.first { $0.kind == .done } }

    /// 头像此刻是哪一拍，规则只在这里。刚做完（`justDone`，与数字账同一个 `doneWindow`，到点一起收）先于等子代理交回（`Tally.delegating`，截之前数的）。
    /// 等子代理交回按件（推进中那件没有会话在跑、有会话在等子代理），不按 `subagents`：那个数也数在跑的会话带的子代理，等子代理的会话名册为空时又是 0。
    var beat: CueBeat {
        switch cue {
        case .away(_, let failed): failed ? .failed : .away
        case .working: .thinking
        case .hearing: .hearing
        case .idle: needsYou > 0 ? .waiting : justDone != nil ? .done : tally.delegating > 0 ? .delegating : .resting
        }
    }

    var isAway: Bool { if case .away = cue { true } else { false } }

    var isBusy: Bool {
        switch cue {
        case .hearing, .working: true
        case .away, .idle: false
        }
    }

    /// 随快照写进 App Group 的是两种各几件，小组件与实时活动只读不另算。
    var needsYou: Int { tally.needsYou }

    /// 当前有确认的活动才可新建；未确认只能保留已有活动。
    var hasConfirmedActivity: Bool { isBusy || needsYou > 0 || tally.moving > 0 || agentCount.map { $0 > 0 } == true }

    /// 未确认不等于全部完成；只有明确没有活（歇着与刚做完）时才允许现有生命周期收尾。
    var isLive: Bool { hasConfirmedActivity || unconfirmed }

    var staleAfter: TimeInterval { isBusy ? Self.fastStale : Self.slowStale }
    var staleAt: Date { min(at.addingTimeInterval(staleAfter), cueUntil ?? .distantFuture) }

    /// 过时只撤销运行断言；没有完成证据，不据此结束活动。
    var settled: CueNow {
        guard isBusy else { return self }
        var now = self
        now.cue = .away(String(localized: "状态未确认"), failed: false)
        now.unconfirmed = true
        return now
    }

    func aged(to date: Date) -> CueNow {
        var now = self
        now.items.removeAll { !$0.isFresh(at: date) }
        return now
    }

    func nextChange(after date: Date) -> Date? {
        items.compactMap(\.expiry).filter { $0 > date }.min()
    }

    /// 推出后再没收到新一份时，到 `date` 该画成的样子。
    func shown(at date: Date) -> CueNow {
        var now = date >= staleAt ? settled : self
        for step in decay where step.at <= date { now.apply(step) }
        return now.aged(to: date)
    }

    func nextShownChange(after date: Date) -> Date? {
        [nextChange(after: date), staleAt > date && self != settled ? staleAt : nil, decay.first { $0.at > date }?.at].compactMap { $0 }.min()
    }

    /// 内容一样（不看推出的时刻）：一样的不重画、不重发。
    func same(as other: CueNow) -> Bool {
        var other = other
        if isBusy || other.isBusy, staleAt != other.staleAt { return false }
        other.at = at
        return self == other
    }

    static let empty = CueNow(
        name: "Cue", cue: .idle, tally: Tally(), advancing: 0, subagents: 0, items: [], first: nil, at: .distantPast)
}

nonisolated extension CueNow: SnapshotFile { static let fileName = "cue-v2.json" }

nonisolated extension CueNow {
    struct Entry: Hashable, Sendable, Identifiable {
        enum Kind: Hashable, Sendable {
            case asks, reply, advancing, subagents
        }

        let kind: Kind
        let count: Int
        var id: Kind { kind }

        /// 读屏念的整句（"4 件推进中"）：每种一个键，英文的复数与语序在目录里。
        var spoken: String {
            switch kind {
            case .asks: String(localized: "\(count) 件拍板")
            case .reply: String(localized: "\(count) 件新回复")
            case .advancing: String(localized: "\(count) 件推进中")
            case .subagents: String(localized: "\(count) 个子代理在跑")
            }
        }

        var tone: Tone {
            switch kind {
            case .asks: .asks
            case .reply: .reply
            case .advancing, .subagents: .moving
            }
        }
    }

    var yours: [Entry] {
        [Entry(kind: .asks, count: tally.asks), Entry(kind: .reply, count: tally.reply)].filter { $0.count > 0 }
    }

    var moving: [Entry] {
        guard tally.moving > 0 else { return [] }
        return [Entry(kind: .advancing, count: advancing), Entry(kind: .subagents, count: subagents)].filter { $0.count > 0 }
    }

    /// Cue 不在时照写：活还在、拍板还等着你，不在只由头像变淡说（原因在没有可数时、在设置与 Cue 页里）。
    var ledger: [[Entry]] {
        guard !(yours.isEmpty && moving.isEmpty) else { return [] }
        return [yours + moving] + (moving.count > 1 ? [yours + moving.prefix(1)] : [])
    }

    /// 没有可数的时那一句。用工具时那一步，不然谁叫醒的，都没有时"思考中"，同 Cue 页对话末尾那一行（`CuePresence.progress`）。
    var quietLine: String {
        switch cue {
        case .away(let reason, _): reason
        case .hearing: String(localized: "你的话在路上")
        case .working(let woke, let doing, _): doing ?? woke ?? Self.thinking
        case .idle:
            if unconfirmed {
                String(localized: "状态未确认")
            } else if let done = justDone {
                String(localized: "刚做完「\(done.name)」")
            } else if advancing > 0 {
                String(localized: "推进中 \(advancing) 件，都空闲")
            } else {
                elsewhere ?? Self.quiet
            }
        }
    }

    var step: String? {
        guard !ledger.isEmpty else { return nil }
        return switch cue {
        case .hearing: String(localized: "你的话在路上")
        case .working(let woke, let doing, _): Dotted(doing ?? woke ?? Self.thinking, doing == nil ? nil : woke).visible
        case .away, .idle: nil
        }
    }

    var quietWord: String? {
        switch cue {
        case .away: String(localized: "不在")
        case .hearing: String(localized: "在听")
        case .working: String(localized: "在想")
        case .idle: justDone == nil ? nil : String(localized: "做完")
        }
    }

    var keyTone: Tone {
        if tally.asks > 0 { return .asks }
        if tally.reply > 0 { return .reply }
        return isBusy || !moving.isEmpty ? .moving : .quiet
    }

    var spoken: String {
        guard let entries = ledger.first else { return quietLine }
        return Dotted(entries.map(\.spoken)).spoken
    }
}

nonisolated extension CueNow {
    /// 颜色的意思，各处只按它取色（`Tone.color`）。
    enum Tone { case moving, asks, reply, done, quiet }
}

nonisolated extension CueNow.Item.Kind {
    var tone: CueNow.Tone {
        switch self {
        case .asks: .asks
        case .reply: .reply
        case .running, .delegating: .moving
        case .done: .done
        case .resting, .unconfirmed: .quiet
        }
    }

    var label: String {
        switch self {
        case .asks: String(localized: "等你拍板")
        case .reply: String(localized: "新回复")
        case .running: String(localized: "在跑")
        case .delegating: String(localized: "等子代理")
        case .resting: String(localized: "歇着")
        case .unconfirmed: String(localized: "状态未确认")
        case .done: String(localized: "做完")
        }
    }
}
