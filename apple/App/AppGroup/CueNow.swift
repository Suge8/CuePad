import Foundation

/// Cue 此刻（WORDS.md「推进中」「等你」「待回复」）：各端 Cue 那一行的第二行（三端侧栏、手机与 iPad 的 Cue 页头、菜单栏面板与输入条）、小组件、
/// iPhone 的灵动岛与锁屏读的唯一一份。App 由库推出（`CueNow.init(_:at:)`，从 Cue 的摘要 `CueDigest`），这里只有规则，各处只画（`CueNowViews`）。
/// - Cue 自己（`cue`）：不在（没启用、睡着、起不来，带那一句原因）、歇着、你的话在路上、在一轮里（谁叫醒的、此刻那一步、从几点起）。
/// - 手上的活（`beads`）：一颗珠子一份——等你的每一件，待回复的每个会话，推进中的每一件（在跑、等子代理交回、歇着），刚做完的顶层任务；按这个先后排。
/// - 那一句（`headline`）：先说 Cue 自己，再说要你拍板的，再说待回复的会话，再说交出去还在动的活，再说刚做完的，最后是静着；紧凑态说的那一件是 `focus`。
///   拍板与待回复不拼成一句：有拍板只说拍板，待回复的珠子在旁边。
///   刚做完只是一瞬的事，不压住此刻在动的：有活在跑时它只是一颗绿珠子，手上没别的了才轮到它说。
/// - 快的事实（Cue 在想、话在路上）几分钟就变，后台的岛不一定等得到下一份：过了 `staleAt` 只信慢的（`settled`）。
/// 刚做完的珠子只留 `doneWindow`：到点由读的一方按时刻收掉（`aged(to:)`、`nextChange(after:)`），不另计时；
/// 推出之后自己不会再收到新一份的（小组件、实时活动）按 `shown(at:)` 画、在 `nextShownChange(after:)` 那一刻让系统重画。
nonisolated struct CueNow: Codable, Hashable, Sendable {
    var name: String
    /// 头像的表情；歇下来时的那一个（`restingMood`）给过时的那份用。
    var mood: CueMood
    var restingMood: CueMood
    var cue: Brain
    /// 至多 `beadLimit` 颗，多出的只记个数（`hidden`）。
    var beads: [Bead]
    var hidden: Int
    /// 截掉之前各种各几份：那一句数的是它，不是排得下的那几颗。
    var counts: Counts
    /// 推进中几件（`CueTally.advancing`）。
    var advancing: Int
    /// 第一件等你：说什么、"打开"去哪，只有 Cue 带选项的提问能"允许一次"（会话在问的只给打开）。
    var first: Wait?
    var at: Date
    /// Mac 上它运行在别的 Mac 时那一句（"在「Mac Studio」上运行"）：静着、手上没有事时那一句写它；Mac Cue 页输入框工具排末尾的旁注也写它。这台或手机上为 nil。
    var elsewhere: String? = nil

    enum Brain: Codable, Hashable, Sendable {
        /// 此刻不会接话：那一句原因（"「Mac Studio」没开"、换新 Mac 时"正在从 iCloud 同步…"），起不来时 `failed`。
        case away(String, failed: Bool)
        case idle
        /// 你最近一句还在路上。
        case hearing
        /// 在一轮里：谁叫醒的（"被 canvas-zoom 叫醒"那一截，不知道为 nil）、此刻那一步（"读取 CueRules.swift"）、这一轮从几点起。
        case working(woke: String?, doing: String?, since: Date)
    }

    struct Bead: Codable, Hashable, Sendable, Identifiable {
        /// 声明的先后就是排的先后（珠子、读屏）。
        enum Kind: String, Codable, Sendable, CaseIterable {
            /// 等你拍板
            case asks
            /// 待回复：Cue 留给你回的会话（墨色，赭黄只给拍板）
            case reply
            /// 有会话在跑（在想、用工具、正在开、话正送进去）
            case running
            /// 会话歇着、等它派出去的子代理交回
            case delegating
            /// 推进中、此刻没在跑
            case resting
            /// 刚做完的顶层任务
            case done
        }

        /// 那一份活的 id（`CueWork.id`、`CueTally.Wait.id`，待回复的是 "reply/会话 id"，刚做完的是 "done/任务 id"）。
        var id: String
        var kind: Kind
        var name: String
        /// 停在这个样子的起点（计时从它走；刚做完的是做完的时刻）。
        var since: Date
        var subagents: Int
        /// 这份活的 Pi 会话 id：接力落在这颗珠子上（`relaySpot(bead:)`）。
        var sessions: [String]

        /// 到这一刻收掉：刚做完的只留 `doneWindow`，别的不按时刻收。
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

    static let beadLimit = 8
    /// 刚做完的那颗留多久。
    static let doneWindow: TimeInterval = 10 * 60
    /// 一份写下后多久算过时：在一轮里、话在路上这类快的事实几分钟就变，其余慢。
    static let fastStale: TimeInterval = 3 * 60
    static let slowStale: TimeInterval = 15 * 60
    static let quiet = "手上没有事"
    /// 在一轮里、没在用工具也不知道谁叫醒的那一句：同会话与对话末尾的状态词（`PiShown` 的 working）。
    static let thinking = "思考中"

    var justDone: Bead? { beads.first { $0.kind == .done } }

    var isAway: Bool { if case .away = cue { true } else { false } }
    private var isFast: Bool {
        switch cue {
        case .hearing, .working: true
        case .away, .idle: false
        }
    }

    /// 有活才开着实时活动：Cue 在一轮里或话在路上、有等你的、有在跑或等子代理的；只剩歇着与刚做完的就结束。
    var isLive: Bool { isFast || beads.contains { $0.kind.tone == .asks || $0.kind.tone == .moving } }

    /// 这一份过多久不可信。
    var staleAfter: TimeInterval { isFast ? Self.fastStale : Self.slowStale }
    var staleAt: Date { at.addingTimeInterval(staleAfter) }

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
        now.beads.removeAll { !$0.isFresh(at: date) }
        return now
    }

    /// `date` 之后这一份下一次因时刻而变的那一刻（刚做完的那颗收掉）；没有为 nil。
    func nextChange(after date: Date) -> Date? {
        beads.compactMap(\.expiry).filter { $0 > date }.min()
    }

    /// 推出后再没收到新一份时，到 `date` 该画成的样子：过了 `staleAt` 只信慢的事实，刚做完的到点收掉。
    func shown(at date: Date) -> CueNow { (date >= staleAt ? settled : self).aged(to: date) }

    /// `date` 之后 `shown(at:)` 下一次变的那一刻（过时、刚做完的收掉）；没有为 nil。
    func nextShownChange(after date: Date) -> Date? {
        [nextChange(after: date), staleAt > date && self != settled ? staleAt : nil].compactMap { $0 }.min()
    }

    /// 那一句（Cue 那一行、岛与锁屏的头一行）：在一轮里用工具时说此刻那一步（`doing`），不然说谁叫醒的、都没有时说"思考中"——
    /// 与 Cue 页对话末尾那一行（`CuePresence.progress`）同一个说法，同屏页头与末尾不各说各的。
    var headline: String {
        switch cue {
        case .away(let reason, _): return reason
        case .hearing: return "你的话在路上"
        case .working(let woke, let doing, _): return doing ?? woke ?? Self.thinking
        case .idle:
            if counts[.asks] > 0 { return "\(counts[.asks]) 件等你拍板" }
            if counts[.reply] > 0 { return "\(counts[.reply]) 个会话待回复" }
            if counts.subagents > 0 { return "等 \(counts.subagents) 个子代理交回" }
            if counts[.running] > 0 { return "\(counts[.running]) 件在跑" }
            if let done = justDone { return "刚做完「\(done.name)」" }
            if advancing > 0 { return "推进中 \(advancing) 件，都歇着" }
            return elsewhere ?? Self.quiet
        }
    }

    /// 各种活一共几份（`counts`），连同等子代理的那几份里在跑的子代理数。
    struct Counts: Codable, Hashable, Sendable {
        private var kinds: [Bead.Kind: Int]
        private(set) var subagents: Int

        init(_ beads: [Bead]) {
            kinds = Dictionary(grouping: beads, by: \.kind).mapValues(\.count)
            subagents = beads.filter { $0.kind == .delegating }.reduce(0) { $0 + $1.subagents }
        }

        subscript(kind: Bead.Kind) -> Int { kinds[kind] ?? 0 }
    }

    /// 灵动岛紧凑态头像旁说的那一件：短词、走秒的起点与颜色只在这里一起定，不会词说做完、秒在计另一件。
    /// Cue 在一轮里或话在路上最先（它正在动），不在写不在；歇着时是手上最该看的那份活，先后同那一句：
    /// 最早等你的、最早待回复的、推进中（在跑与等子代理交回，WORDS.md）最早的那份、刚做完的；只剩歇着的写歇着、不计时。
    var focus: (word: String, tone: Tone, since: Date?) {
        switch cue {
        case .away: return ("不在", .quiet, nil)
        case .hearing: return ("在听", .moving, nil)
        case .working(_, _, let since): return ("在想", .moving, since)
        case .idle:
            let earliest = { (tone: Tone) in self.beads.filter { $0.kind.tone == tone }.min { $0.since < $1.since } }
            guard let lead = earliest(.asks) ?? earliest(.reply) ?? earliest(.moving) ?? justDone else { return ("歇着", .quiet, nil) }
            return (lead.kind.word, lead.kind.tone, lead.since)
        }
    }

    /// 那一句之外另起一行的（岛与锁屏）：用工具时那一句说的是此刻那一步，谁叫醒的写在这里；其余为 nil。
    var aside: String? { if case .working(let woke?, _?, _) = cue { woke } else { nil } }

    /// 内容一样（不看推出的时刻）：一样的不重画、不重发。
    func same(as other: CueNow) -> Bool {
        var other = other
        other.at = at
        return self == other
    }

    static let empty = CueNow(
        name: "Cue", mood: .sleeping, restingMood: .sleeping, cue: .idle, beads: [], hidden: 0, counts: Counts([]), advancing: 0, first: nil, at: .distantPast)
}

nonisolated extension CueNow: SnapshotFile { static let fileName = "cue.json" }

nonisolated extension CueNow {
    /// 颜色的意思，各处只按它取色（`Tone.color`）：在动（在跑、等子代理交回、Cue 在想或话在路上）、等你、待回复、刚做完、其余。
    enum Tone { case moving, asks, reply, done, quiet }
}

nonisolated extension CueNow.Bead.Kind {
    var tone: CueNow.Tone {
        switch self {
        case .asks: .asks
        case .reply: .reply
        case .running, .delegating: .moving
        case .done: .done
        case .resting: .quiet
        }
    }

    /// 紧凑态的短词：在跑与等子代理交回都是推进中，两者靠珠子的实心、空心与那一句分。
    var word: String {
        switch self {
        case .asks: "等你"
        case .reply: "待回复"
        case .running, .delegating: "推进中"
        case .done: "做完"
        case .resting: "歇着"
        }
    }

    /// 这颗珠子的样子写成字（展开态与锁屏的每一行、读屏）。
    var label: String {
        switch self {
        case .asks: "等你拍板"
        case .reply: "待回复"
        case .running: "在跑"
        case .delegating: "等子代理"
        case .resting: "歇着"
        case .done: "做完"
        }
    }
}

/// 头像的表情（`Assets` 里的 mascot-cue-*）。App 里按 Cue 在不在、有没有等你推（`CueMood.of`），扩展只读 Cue 此刻里存的那个。
nonisolated enum CueMood: String, Codable, Sendable {
    case thinking, waiting, done, sleeping, listening

    var asset: String { "mascot-cue-\(rawValue)" }
}
