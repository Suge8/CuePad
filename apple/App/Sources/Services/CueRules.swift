import CueStore
import CueText
import Foundation

nonisolated enum CuePresence: Equatable, Sendable {
    case disabled
    case asleep
    case unconfirmed(String)
    case idle
    case sending(DeliveryShown.Transit)
    case working(WorkState, detail: String?, step: CueActivity.Touch?)
    case unreachable(String)

    static func derive(_ digest: CueDigest, at moment: Speech.Moment) -> CuePresence {
        guard digest.enabled else { return .disabled }
        let trip = digest.lastYou.map {
            Speech.trip(said: $0.said, delivered: $0.delivered, reachedServer: $0.reachedServer, host: digest.hostID, at: moment)
        }
        if !digest.hostOnline && moment.reachableSince(digest.hostID) != nil { return .asleep }
        if case .unconfirmed(let reason) = trip { return .unconfirmed(reason) }
        if let trip, trip.inTransit { return .sending(trip == .sent ? .sent : .sending) }
        if !digest.hostOnline { return .unconfirmed(String(localized: "状态未确认")) }
        guard let state = digest.state else { return .idle }
        guard let work = state.runtimeState.known else { return .unconfirmed(String(localized: "状态未确认")) }
        if work == .error { return .unreachable(state.detail ?? String(localized: "\(digest.name) 起不来了")) }
        return work.isWorking ? .working(work, detail: state.detail, step: state.step) : .idle
    }

    var isAway: Bool {
        switch self {
        case .disabled, .asleep, .unconfirmed, .unreachable: true
        case .idle, .sending, .working: false
        }
    }

    var isUnconfirmed: Bool { if case .unconfirmed = self { true } else { false } }

    var isUnreachable: Bool { if case .unreachable = self { true } else { false } }

    var isUsingTool: Bool { if case .working(.tool, _, _) = self { true } else { false } }

    var shown: SessionShown? {
        switch self {
        case .sending(let transit): SessionShown(status: .delivery(.inTransit(transit)))
        case .working(let state, _, _): SessionShown(status: .working(state))
        case .disabled, .asleep, .unconfirmed, .idle, .unreachable: nil
        }
    }

    var progress: String? {
        guard case .working(_, let detail, let step) = self else { return nil }
        return step.map(CueActivity.line) ?? detail.flatMap(SessionProgress.action).map(SessionProgress.gist) ?? shown?.label
    }

    func line(host: String, ranBefore: Bool) -> String? {
        switch self {
        case .disabled: ranBefore ? String(localized: "已停用") : String(localized: "还没启用")
        case .asleep: String(localized: "「\(host)」没开")
        case .unconfirmed(let reason): reason
        case .unreachable(let reason): reason
        case .idle, .sending, .working: nil
        }
    }
}

nonisolated struct CueDigest: Equatable, Sendable {
    var name: String
    var enabled: Bool
    var hostID: String?
    var hostName: String?
    var macNames: [String: String] = [:]
    var tally: CueTally
    var advancing: Int { tally.advancing.count }
    var unread: Int
    var hostUntil: Date?
    var hostOnline: Bool { hostUntil != nil }
    var lastYou: LastYou?
    var state: CueState?
    var woke: Woke?
    var done: [Card]

    static let empty = CueDigest(
        name: CueProfile.defaultName, enabled: false, hostID: nil, hostName: nil, tally: .empty, unread: 0, hostUntil: nil,
        lastYou: nil, state: nil, woke: nil, done: [])

    struct Woke: Equatable, Sendable {
        var at: Date
        var text: String
        var sessions: [String]?
    }

    struct LastYou: Equatable, Sendable {
        var said: Date
        var delivered: Date?
        var reachedServer: Bool
    }

    static func read(from store: isolated CueStore) throws -> CueDigest {
        let profile = try store.cueProfile()
        let tally = try store.cueTally()
        return CueDigest(
            name: profile?.name ?? CueProfile.defaultName,
            enabled: profile?.activeHost != nil,
            hostID: profile?.hostID,
            hostName: try profile?.hostID.map { try store.macAgents(on: $0).shownName },
            macNames: Dictionary(try store.allMacAgents().map { ($0.hostID, $0.shownName) }) { first, _ in first },
            tally: tally,
            unread: try store.cueUnread().count,
            hostUntil: try profile?.activeHost.flatMap { try store.macOnlineUntil($0) },
            lastYou: try store.cueLastYou().map { LastYou(said: $0.said, delivered: $0.delivered, reachedServer: $0.reachedServer) },
            state: try store.cueState(),
            woke: try store.cueWaking().map { row in
                var seen = Set<String>()
                let sessions: [String]? = if case .sessionActivity(let stirs)? = row.wake {
                    stirs.compactMap(\.session).filter { seen.insert($0).inserted }
                } else { nil }
                return Woke(at: row.createdAt, text: Self.woke(row), sessions: sessions)
            },
            done: try store.tasksDone(since: Calendar.current.startOfDay(for: store.timing.now())).filter { TaskBoard.Column.of($0, in: tally) == .done })
    }

    private static func woke(_ row: CueMessage) -> String {
        switch row.wake! {
        case .message: return String(localized: "在回你的话")
        case .idle: return String(localized: "例行查看")
        case .schedule: return String(localized: "定时到点")
        case .enabled: return String(localized: "刚启用")
        case .sessionActivity(let stirs):
            var seen = Set<String>()
            let sessions = stirs.filter { $0.session.map { seen.insert($0).inserted } ?? false }
            guard let first = sessions.first else { return String(localized: "有一件做完了") }
            let name = row.name(session: first.session!)
            return sessions.count > 1 ? String(localized: "被 \(name) 等 \(sessions.count) 处叫醒") : String(localized: "被 \(name) 叫醒")
        }
    }

}

nonisolated struct CueFlight: Equatable, Sendable {
    enum Direction: Sendable {
        case wake
        case relay
    }

    let direction: Direction
    let at: Date
    let ends: [RelayEnd]

    private static let spoken: Set<DeliveryMode> = [.send, .answer]

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

    struct Facts: Equatable, Sendable {
        var handed: [Handed]

        static func read(from store: isolated CueStore) throws -> Facts { Facts(handed: try Handed.read(from: store)) }

        func flight(after seen: Date?) -> CueFlight? {
            let fresh = handed.filter { $0.at > seen ?? .distantPast }.sorted { $0.at > $1.at }
            return fresh.first.map { CueFlight(direction: .relay, at: $0.at, ends: fresh.map(\.end)) }
        }

        var latest: Date? { handed.map(\.at).max() }
    }
}


