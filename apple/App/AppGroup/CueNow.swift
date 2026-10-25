import Foundation

/// Cue 此刻（WORDS.md「推进中」「等你」「待回复」）：各端 Cue 那一行（三端侧栏、手机与 iPad 的名牌、菜单栏面板与输入条）、小组件、
/// iPhone 的灵动岛与锁屏、App 图标与菜单栏图标的角标读的唯一一份。App 由库推出（`CueNow.init(_:at:local:)`，从 Cue 的摘要 `CueDigest`），这里只有规则，各处只画（`CueNowViews`）。
/// - Cue 自己（`cue`）：不在（没启用、睡着、起不来，带那一句原因）、歇着、你的话在路上、在一轮里（谁叫醒的、此刻那一步、从几点起）。头像的表情（`mood`）也在这里，各处的头像只读它。
/// - 数字账（`ledger`）：几种活各几件（Cue 不在时也照写），按件数（一件是看板上的一张卡，`CueTally`），不按会话数。要你管的（拍板、待回复）在前，推进中的（在跑、等子代理交回）在后；
///   歇着的不写（看板上看得到），为 0 的不写；放不下时在跑与等子代理并成"N 推进中"（与底部那一排的"推进中 N"同一个数，`advancing`）。
///   不再挑一句说：几件、各什么样子、几件要你管同时摆出来。都没有时一句安静的现状（`quietLine`）。
/// - 角标（`needsYou`）：拍板加待回复，App 图标、菜单栏图标与灵动岛最小态同一个数。
/// - 每件一行（`items`）：展开态与锁屏下面列的那几件，等你的每一件、待回复的每个会话、推进中的每一件（在跑、等子代理交回、歇着）、刚做完的顶层任务；按这个先后排。
/// - 快的事实（Cue 在想、话在路上）几分钟就变，后台的岛不一定等得到下一份：过了 `staleAt` 只信慢的（`settled`）。
/// 刚做完的那件只留 `doneWindow`：到点由读的一方按时刻收掉（`aged(to:)`、`nextChange(after:)`），不另计时；
/// 推出之后自己不会再收到新一份的（小组件、实时活动）按 `shown(at:)` 画、在 `nextShownChange(after:)` 那一刻让系统重画。
nonisolated struct CueNow: Codable, Hashable, Sendable {
    var name: String
    /// 头像的表情；歇下来时的那一个（`restingMood`）给过时的那份用。
    var mood: CueMood
    var restingMood: CueMood
    var cue: Brain
    /// 截掉之前各种各几件：数字账与角标数的是它，不是列得下的那几行。
    var tally: Tally
    /// 推进中几件（`CueTally.advancing`，含歇着的）。
    var advancing: Int
    /// 至多 `itemLimit` 件。
    var items: [Item]
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

    /// 各种几件（推进中的只数在跑与等子代理的，歇着的不进数字账）。
    struct Tally: Codable, Hashable, Sendable {
        var asks = 0
        var reply = 0
        var running = 0
        var delegating = 0

        /// "等你 N"：拍板加待回复，这条规则只在这里（`CueNow.needsYou`）。
        var needsYou: Int { asks + reply }
    }

    /// 一件：展开态与锁屏下面的一行。
    struct Item: Codable, Hashable, Sendable, Identifiable {
        /// 声明的先后就是排的先后。
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

    static let itemLimit = 8
    /// 刚做完的那件留多久。
    static let doneWindow: TimeInterval = 10 * 60
    /// 一份写下后多久算过时：在一轮里、话在路上这类快的事实几分钟就变，其余慢。
    static let fastStale: TimeInterval = 3 * 60
    static let slowStale: TimeInterval = 15 * 60
    static let quiet = String(localized: "手上没有事")
    /// 在一轮里、没在用工具也不知道谁叫醒的那一句：同会话与对话末尾的状态词（`PiShown` 的 working）。
    static let thinking = String(localized: "思考中")

    var justDone: Item? { items.first { $0.kind == .done } }

    var isAway: Bool { if case .away = cue { true } else { false } }

    /// Cue 在一轮里或你的话在路上：头像右下那颗靛青的点。
    var isBusy: Bool {
        switch cue {
        case .hearing, .working: true
        case .away, .idle: false
        }
    }

    /// "等你 N"：要你管的几件，拍板加待回复（`Tally.needsYou`）：头像的表情、底部那一排与侧栏进展那一行、入口的点、App 图标与菜单栏图标的角标、灵动岛最小态都读它；
    /// 随快照写进 App Group 的是两种各几件，小组件与实时活动只读不另算。
    var needsYou: Int { tally.needsYou }

    /// 有活才开着实时活动：Cue 在一轮里或话在路上、有等你的（拍板与待回复）、有在跑或等子代理的；只剩歇着与刚做完的就结束。
    var isLive: Bool { isBusy || needsYou > 0 || tally.running + tally.delegating > 0 }

    /// 这一份过多久不可信。
    var staleAfter: TimeInterval { isBusy ? Self.fastStale : Self.slowStale }
    var staleAt: Date { at.addingTimeInterval(staleAfter) }

    /// 过时之后只信慢的事实：Cue 按歇着算（表情也换回歇着的那个）。
    var settled: CueNow {
        guard isBusy else { return self }
        var now = self
        now.cue = .idle
        now.mood = restingMood
        return now
    }

    /// 到 `date` 时的样子：刚做完的过了 `doneWindow` 就收掉。
    func aged(to date: Date) -> CueNow {
        var now = self
        now.items.removeAll { !$0.isFresh(at: date) }
        return now
    }

    /// `date` 之后这一份下一次因时刻而变的那一刻（刚做完的那件收掉）；没有为 nil。
    func nextChange(after date: Date) -> Date? {
        items.compactMap(\.expiry).filter { $0 > date }.min()
    }

    /// 推出后再没收到新一份时，到 `date` 该画成的样子：过了 `staleAt` 只信慢的事实，刚做完的到点收掉。
    func shown(at date: Date) -> CueNow { (date >= staleAt ? settled : self).aged(to: date) }

    /// `date` 之后 `shown(at:)` 下一次变的那一刻（过时、刚做完的收掉）；没有为 nil。
    func nextShownChange(after date: Date) -> Date? {
        [nextChange(after: date), staleAt > date && self != settled ? staleAt : nil].compactMap { $0 }.min()
    }

    /// 内容一样（不看推出的时刻）：一样的不重画、不重发。
    func same(as other: CueNow) -> Bool {
        var other = other
        other.at = at
        return self == other
    }

    static let empty = CueNow(
        name: "Cue", mood: .sleeping, restingMood: .sleeping, cue: .idle, tally: Tally(), advancing: 0, items: [], first: nil, at: .distantPast)
}

nonisolated extension CueNow: SnapshotFile { static let fileName = "cue.json" }

nonisolated extension CueNow {
    /// 数字账的一项：哪一种、几件。
    struct Entry: Hashable, Sendable, Identifiable {
        enum Kind: Hashable, Sendable {
            case asks, reply, running, delegating
            /// 在跑与等子代理并成的那一项（数是 `advancing`）。
            case advancing
        }

        let kind: Kind
        let count: Int
        var id: Kind { kind }

        /// 读屏念的整句（"3 件在跑"）：每种一个键，英文的复数与语序在目录里。
        var spoken: String {
            switch kind {
            case .asks: String(localized: "\(count) 件拍板")
            case .reply: String(localized: "\(count) 件待回复")
            case .running: String(localized: "\(count) 件在跑")
            case .delegating: String(localized: "\(count) 件等子代理")
            case .advancing: String(localized: "\(count) 件推进中")
            }
        }

        var tone: Tone {
            switch kind {
            case .asks: .asks
            case .reply: .reply
            case .running, .delegating, .advancing: .moving
            }
        }
    }

    /// 要你管的：拍板、待回复（为 0 的不写）。
    var yours: [Entry] {
        [Entry(kind: .asks, count: tally.asks), Entry(kind: .reply, count: tally.reply)].filter { $0.count > 0 }
    }

    /// 推进中的：在跑、等子代理（为 0 的不写，歇着的不写）。
    var moving: [Entry] {
        [Entry(kind: .running, count: tally.running), Entry(kind: .delegating, count: tally.delegating)].filter { $0.count > 0 }
    }

    /// 数字账由细到粗的几排（排得下哪排画哪排）：全列；在跑与等子代理并成推进中。都没有时为空，写 `quietLine`。
    /// Cue 不在时照写：活还在、拍板还等着你，不在只由头像变淡说（原因在没有可数时、在设置与 Cue 页里）。
    var ledger: [[Entry]] {
        guard !(yours.isEmpty && moving.isEmpty) else { return [] }
        let merged = moving.isEmpty ? [] : [yours + [Entry(kind: .advancing, count: advancing)]]
        return [yours + moving] + merged
    }

    /// 没有可数的时那一句：不在的原因、你的话在路上、Cue 此刻那一步（用工具时那一步，不然谁叫醒的，都没有时"思考中"，
    /// 同 Cue 页对话末尾那一行 `CuePresence.progress`）、刚做完、都歇着、在别的 Mac 上运行、手上没有事。
    var quietLine: String {
        switch cue {
        case .away(let reason, _): reason
        case .hearing: String(localized: "你的话在路上")
        case .working(let woke, let doing, _): doing ?? woke ?? Self.thinking
        case .idle:
            if let done = justDone {
                String(localized: "刚做完「\(done.name)」")
            } else if advancing > 0 {
                String(localized: "推进中 \(advancing) 件，都歇着")
            } else {
                elsewhere ?? Self.quiet
            }
        }
    }

    /// 有数字账时 Cue 自己此刻那一步另起一行（岛与锁屏的下半）：话在路上、在一轮里的那一步与谁叫醒的；其余为 nil。
    var step: String? {
        guard !ledger.isEmpty else { return nil }
        return switch cue {
        case .hearing: String(localized: "你的话在路上")
        case .working(let woke, let doing, _): Dotted(doing ?? woke ?? Self.thinking, doing == nil ? nil : woke).visible
        case .away, .idle: nil
        }
    }

    /// 灵动岛紧凑态没有可数时头像旁的短词：不在、在听、在想、做完；都不是为 nil。
    var quietWord: String? {
        switch cue {
        case .away: String(localized: "不在")
        case .hearing: String(localized: "在听")
        case .working: String(localized: "在想")
        case .idle: justDone == nil ? nil : String(localized: "做完")
        }
    }

    /// 灵动岛描边的颜色：有拍板赭黄，只有待回复墨色，Cue 在动或有推进中的靛青，其余淡。
    var keyTone: Tone {
        if tally.asks > 0 { return .asks }
        if tally.reply > 0 { return .reply }
        return isBusy || !moving.isEmpty ? .moving : .quiet
    }

    /// 读屏：数字账（"1 件拍板，3 件在跑"），没有时那一句。
    var spoken: String {
        guard let entries = ledger.first else { return quietLine }
        return Dotted(entries.map(\.spoken)).spoken
    }
}

nonisolated extension CueNow {
    /// 颜色的意思，各处只按它取色（`Tone.color`）：在动（在跑、等子代理交回、Cue 在想或话在路上）、拍板、待回复、刚做完、其余。
    enum Tone { case moving, asks, reply, done, quiet }
}

nonisolated extension CueNow.Item.Kind {
    var tone: CueNow.Tone {
        switch self {
        case .asks: .asks
        case .reply: .reply
        case .running, .delegating: .moving
        case .done: .done
        case .resting: .quiet
        }
    }

    /// 这一件的样子写成字（展开态与锁屏的每一行）。
    var label: String {
        switch self {
        case .asks: String(localized: "等你拍板")
        case .reply: String(localized: "待回复")
        case .running: String(localized: "在跑")
        case .delegating: String(localized: "等子代理")
        case .resting: String(localized: "歇着")
        case .done: String(localized: "做完")
        }
    }
}

/// 头像的表情（`Assets` 里的 mascot-cue-*）。App 里按 Cue 在不在、有没有等你推（`CueMood.of`），扩展只读 Cue 此刻里存的那个。
nonisolated enum CueMood: String, Codable, Sendable {
    case thinking, waiting, done, sleeping, listening

    var asset: String { "mascot-cue-\(rawValue)" }
}
