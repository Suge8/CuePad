import Foundation

/// Cue 此刻（WORDS.md「推进中」「等你」）：各端 Cue 那一行的第二行（三端侧栏、手机与 iPad 的 Cue 页头、菜单栏面板与输入条）、小组件、
/// iPhone 的灵动岛与锁屏读的唯一一份。App 由库推出（`CueNow.init(_:at:)`，从 Cue 的摘要 `CueDigest`），这里只有规则，各处只画（`CueNowViews`）。
/// - Cue 自己（`cue`）：不在（没启用、睡着、起不来，带那一句原因）、歇着、你的话在路上、在一轮里（谁叫醒的、此刻那一步、从几点起）。
/// - 手上的活（`beads`）：一颗珠子一份——等你的每一件，推进中的每一件（在跑、等子代理交回、歇着），刚做完的顶层任务；按这个先后排。
/// - 那一句（`sentence`，窄处写 `headline`）：先说 Cue 自己，再说要你拍板的，再说刚做完的、交出去的活，最后是静着。
/// - 快的事实（Cue 在想、话在路上）几分钟就变，后台的岛不一定等得到下一份：过了 `staleAfter` 只信慢的（`settled`）。
/// 刚做完的珠子只留 `doneWindow`：到点由读的一方按时刻收掉（`aged(to:)`、`nextChange(after:)`），不另计时。
nonisolated struct CueNow: Codable, Hashable, Sendable {
    var name: String
    /// 头像的表情（`CueMood` 的原始值，图在 CueFaces 里）；歇下来时的那一个（`restingMood`）给过时的那份用。
    var mood: String
    var restingMood: String
    var cue: Brain
    /// 至多 `beadLimit` 颗，多出的只记个数（`hidden`）。
    var beads: [Bead]
    var hidden: Int
    /// 推进中几件（`CueTally.advancing`）。
    var advancing: Int
    /// 第一件等你：说什么、"打开"去哪，只有 Cue 带选项的提问能"允许一次"（会话在问的只给打开）。
    var first: Wait?
    /// 这一份是什么时候推出的。
    var at: Date

    enum Brain: Codable, Hashable, Sendable {
        /// 此刻不会接话：那一句原因（"Cue 在睡觉：它运行的那台 Mac 好像没开"），起不来时 `failed`。
        case away(String, failed: Bool)
        case idle
        /// 你最近一句还在路上。
        case hearing
        /// 在一轮里：谁叫醒的（"被 canvas-zoom 叫醒"那一截，不知道为 nil）、此刻那一步（"读取 CueRules.swift"）、这一轮从几点起。
        case working(woke: String?, doing: String?, since: Date)
    }

    struct Bead: Codable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable {
            /// 等你拍板
            case asks
            /// 有会话在跑（在想、用工具、正在开、话正送进去）
            case running
            /// 会话歇着、等它派出去的子代理交回
            case delegating
            /// 推进中、此刻没在跑
            case resting
            /// 刚做完的顶层任务
            case done
        }

        /// 那一份活的 id（`CueWork.id`、`CueTally.Wait.id`，刚做完的是 "done/任务 id"）。
        var id: String
        var kind: Kind
        var name: String
        /// 停在这个样子的起点（计时从它走；刚做完的是做完的时刻）。
        var since: Date
        /// 在跑的子代理几个（等子代理交回时）。
        var subagents: Int
        /// 这份活的 Pi 会话 id：接力落在这颗珠子上（`relaySpot(bead:)`）。
        var sessions: [String]
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

    static let beadLimit = 8
    /// 刚做完的那颗留多久。
    static let doneWindow: TimeInterval = 10 * 60
    /// 一份写下后多久算过时：在一轮里、话在路上这类快的事实几分钟就变，其余慢。
    static let fastStale: TimeInterval = 3 * 60
    static let slowStale: TimeInterval = 15 * 60
    static let quiet = "手上没有事"

    var asks: Int { beads.count { $0.kind == .asks } }
    var running: Int { beads.count { $0.kind == .running } }
    var subagents: Int { beads.filter { $0.kind == .delegating }.reduce(0) { $0 + $1.subagents } }
    var delegating: Int { beads.count { $0.kind == .delegating } }
    var resting: Int { beads.count { $0.kind == .resting } }
    var justDone: Bead? { beads.first { $0.kind == .done } }

    var isAway: Bool { if case .away = cue { true } else { false } }
    private var isFast: Bool {
        switch cue {
        case .hearing, .working: true
        case .away, .idle: false
        }
    }

    /// 有活才开着实时活动：Cue 在一轮里或话在路上、有等你的、有在跑或等子代理的；只剩歇着与刚做完的就结束。
    var isLive: Bool { isFast || beads.contains { [.asks, .running, .delegating].contains($0.kind) } }

    /// 这一份过多久不可信。
    var staleAfter: TimeInterval { isFast ? Self.fastStale : Self.slowStale }

    /// 过时之后只信慢的事实：Cue 按歇着算（表情也换回歇着的那个）。
    var settled: CueNow {
        guard isFast else { return self }
        var now = self
        now.cue = .idle
        now.mood = restingMood
        return now
    }

    /// 到 `date` 时的样子：刚做完的过了 `doneWindow` 就收掉。
    func aged(to date: Date) -> CueNow {
        var now = self
        now.beads.removeAll { $0.kind == .done && $0.since.addingTimeInterval(Self.doneWindow) <= date }
        return now
    }

    /// `date` 之后这一份下一次因时刻而变的那一刻（刚做完的那颗收掉）；没有为 nil。
    func nextChange(after date: Date) -> Date? {
        beads.filter { $0.kind == .done }.map { $0.since.addingTimeInterval(Self.doneWindow) }.filter { $0 > date }.min()
    }

    /// 那一句（岛的展开、锁屏）。
    var sentence: String { line(full: true) }
    /// 窄处那一句（Cue 那一行、紧凑处）：在一轮里只说谁叫醒的，不带此刻那一步。
    var headline: String { line(full: false) }

    private func line(full: Bool) -> String {
        switch cue {
        case .away(let reason, _): return reason
        case .hearing: return "你的话在路上"
        case .working(let woke, let doing, _):
            let woke = woke ?? "在想"
            guard full, let doing else { return woke }
            return Dotted(woke, doing).visible
        case .idle:
            if asks > 0 { return "\(asks) 件等你拍板" }
            if let done = justDone { return "刚做完「\(done.name)」" }
            if subagents > 0 { return "等 \(subagents) 个子代理交回" }
            if running > 0 { return "\(running) 件在跑" }
            if advancing > 0 { return "推进中 \(advancing) 件，都歇着" }
            return Self.quiet
        }
    }

    /// Cue 歇着时紧凑态说的那份活，先后同那一句：最早等你的、刚做完的、最早等子代理交回的、最早在跑的；都没有（只剩歇着的）为 nil。
    /// 短词、走秒与颜色都跟着它，不会出现词说做完、秒在计另一件的。
    var lead: Bead? {
        if let done = justDone, asks == 0 { return done }
        for kind in [Bead.Kind.asks, .delegating, .running] {
            if let first = beads.filter({ $0.kind == kind }).min(by: { $0.since < $1.since }) { return first }
        }
        return nil
    }

    /// 灵动岛紧凑态头像旁的一个短词：Cue 在一轮里最先（它正在动），否则是 `lead` 的样子。
    var word: String {
        switch cue {
        case .away: return "不在"
        case .hearing: return "在听"
        case .working: return "在想"
        case .idle:
            switch lead?.kind {
            case .asks: return "等你"
            case .done: return "做完"
            case .delegating: return "等交回"
            case .running: return "在跑"
            case .resting, nil: return "歇着"
            }
        }
    }

    /// 紧凑态与展开态走秒的起点，跟着短词说的那件：Cue 这一轮从几点起，否则 `lead` 从几点起（做完是做完了多久）。
    var clock: Date? {
        if case .working(_, _, let since) = cue { return since }
        return lead?.since
    }

    /// 在一轮里此刻那一步（"读取 Sources/Zoom.swift"）；没在用工具为 nil。
    var doing: String? { if case .working(_, let doing, _) = cue { doing } else { nil } }

    /// 内容一样（不看推出的时刻）：一样的不重画、不重发。
    func same(as other: CueNow) -> Bool {
        var other = other
        other.at = at
        return self == other
    }

    static let empty = CueNow(
        name: "Cue", mood: "sleeping", restingMood: "sleeping", cue: .idle, beads: [], hidden: 0, advancing: 0, first: nil, at: .distantPast)
}

nonisolated extension CueNow: SnapshotFile { static let fileName = "cue.json" }
