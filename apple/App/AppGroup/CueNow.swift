import Foundation

nonisolated struct CueNow: Codable, Hashable, Sendable {
    var name: String
    var cue: Brain
    var tally: Tally
    var advancing: Int
    var subagents: Int
    var items: [Item]
    var first: Wait?
    var at: Date
    var elsewhere: String? = nil
    var decay: [Decay] = []
    var unconfirmed = false
    var cueUntil: Date? = nil
    var agentCount: Int? = nil
    /// 刚完的（做完、新回复）让已有的实时活动再留到的时刻：两轮之间不收了又开，远程开一只要亮屏提醒、还占系统的额度。
    /// 从没截过的全量里取（`items` 只列得下几行，旧的未读回复会把刚到的挤出去）。
    var lingersUntil: Date? = nil

    enum CodingKeys: String, CodingKey {
        case name, cue, tally, advancing, subagents, items, first, at, elsewhere, agentCount
        case decay = "x", unconfirmed = "u", cueUntil = "v", lingersUntil = "l"
    }

    enum Brain: Codable, Hashable, Sendable {
        case away(String, failed: Bool)
        case idle
        case hearing
        case working(woke: String?, doing: String?, since: Date)
    }

    struct Tally: Codable, Hashable, Sendable {
        var asks = 0
        var reply = 0
        var moving = 0
        var delegating = 0

        enum CodingKeys: String, CodingKey { case asks, reply, moving, delegating }

        var needsYou: Int { asks + reply }
    }

    struct Item: Codable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case asks
            case reply
            case running
            case delegating
            case resting
            case unconfirmed
            case done
        }

        var id: String
        var kind: Kind
        var name: String
        var since: Date
        var subagents: Int
        var slot = 0
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
    }

    static let itemLimit = 8
    static let doneWindow: TimeInterval = 10 * 60
    static let fastStale: TimeInterval = 3 * 60
    static let slowStale: TimeInterval = 15 * 60
    static let quiet = String(localized: "手上没有事")
    static let thinking = String(localized: "思考中")

    var justDone: Item? { items.first { $0.kind == .done } }

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

    var needsYou: Int { tally.needsYou }

    var hasConfirmedActivity: Bool { isBusy || tally.asks > 0 || tally.moving > 0 || agentCount.map { $0 > 0 } == true }

    var isLive: Bool { hasConfirmedActivity || unconfirmed || lingersUntil.map { $0 > at } == true }

    var glance: Set<String> { Set(items.map { "\($0.id)/\($0.kind.tone)" }) }

    var staleAfter: TimeInterval { isBusy ? Self.fastStale : Self.slowStale }
    var staleAt: Date { min(at.addingTimeInterval(staleAfter), cueUntil ?? .distantFuture) }

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

    func shown(at date: Date) -> CueNow {
        var now = date >= staleAt ? settled : self
        for step in decay where step.at <= date { now.apply(step) }
        return now.aged(to: date)
    }

    func nextShownChange(after date: Date) -> Date? {
        [nextChange(after: date), staleAt > date && self != settled ? staleAt : nil, decay.first { $0.at > date }?.at].compactMap { $0 }.min()
    }

    func same(as other: CueNow) -> Bool {
        var other = other
        if isBusy || other.isBusy, staleAt != other.staleAt { return false }
        guard isLive == other.isLive else { return false }
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

        var spoken: String {
            switch kind {
            case .asks: String(localized: "\(count) 件拍板")
            case .reply: String(localized: "\(count) 件新回复")
            case .advancing: String(localized: "\(count) 件推进中")
            case .subagents: String(localized: "\(count) 个子代理工作中")
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

    var ledger: [[Entry]] {
        guard !(yours.isEmpty && moving.isEmpty) else { return [] }
        return [yours + moving] + (moving.count > 1 ? [yours + moving.prefix(1)] : [])
    }

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
        case .running: String(localized: "工作中")
        case .delegating: String(localized: "等子代理")
        case .resting: String(localized: "歇着")
        case .unconfirmed: String(localized: "状态未确认")
        case .done: String(localized: "做完")
        }
    }
}
