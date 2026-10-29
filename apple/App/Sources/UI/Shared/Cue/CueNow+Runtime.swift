import CueStore
import Foundation

nonisolated extension CueWork {
    /// 同一会话绑着多个叶子也只贡献一次。
    var sessions: [PiSessionState] {
        let states = switch self {
        case .task(let item): item.leaves.compactMap(\.session)
        case .session(let session): [session]
        }
        var seen = Set<String>()
        return states.filter { $0.state != .known(.ended) && seen.insert($0.sessionID).inserted }
    }
}

/// 当前状态与未来各 host 到期后的数字账共用同一份归属汇总；不为每个未来时刻重扫全量。
nonisolated struct RuntimeTimeline {
    struct Work {
        var id: String
        var name: String
        var since: Date
        var runningSince: Date?
        var delegatingSince: Date?
        var running = 0
        var delegating = 0
        var unknown = 0
        var agents = 0
        var held = 0
        var pending = false
        var sessionRefs: [Int] = []

        var kind: CueNow.Item.Kind {
            if running > 0 || pending { return .running }
            if delegating > 0 { return .delegating }
            return unknown > 0 ? .unconfirmed : .resting
        }
        var moving: Int { held == 0 && (kind == .running || kind == .delegating) ? 1 : 0 }
        var delegated: Int { held == 0 && kind == .delegating ? 1 : 0 }
        var advancing: Int { held == 0 ? 1 : 0 }

        var item: CueNow.Item {
            let start = switch kind {
            case .running: runningSince ?? since
            case .delegating: delegatingSince ?? since
            default: since
            }
            return CueNow.Item(id: id, kind: kind, name: name, since: start, subagents: kind == .delegating ? agents : 0)
        }
    }

    struct Session {
        var agents: Int
        /// held 只撤销那一件的引用，不能把共享会话的贡献固定给第一件。
        var advancing = 0
        var contribution: Int { advancing > 0 ? agents : 0 }
    }

    struct Removal {
        var work: Int?
        var running = 0
        var delegating = 0
        var agents = 0
        var asks = 0
        var reply = 0
        var pending = false
        var visible: String?
        var unknown = 0
        var startedRunning: Date?
        var startedDelegating: Date?
        var afterRunning: Date?
        var afterDelegating: Date?
        var expiredSessions: [Int] = []

        mutating func merge(_ other: Removal) {
            running += other.running
            delegating += other.delegating
            agents += other.agents
            unknown += other.unknown
            pending = pending || other.pending
            expiredSessions += other.expiredSessions
            startedRunning = [startedRunning, other.startedRunning].compactMap { $0 }.min()
            startedDelegating = [startedDelegating, other.startedDelegating].compactMap { $0 }.min()
        }
    }

    var works: [Work] = []
    var sessions: [Session] = []
    var events: [Date: [Removal]] = [:]
    var dates: ArraySlice<Date> = []
    var tally: CueNow.Tally
    var advancing: Int
    var subagents: Int
    var unconfirmed = false
    var waiting: [(until: Date?, value: CueNow.Wait)] = []
    var firstIndex = 0
    var workSlots: [Int: Int] = [:]
    var shownIDs: [Int: String] = [:]

    init(_ digest: CueDigest, at now: Date) {
        let source = digest.tally
        tally = CueNow.Tally(asks: source.waiting.count, reply: source.replies.count)
        advancing = source.advancing.count
        subagents = 0
        var owners: [String: Int] = [:], sessionRefs: [String: Int] = [:]
        for work in source.works {
            let index = works.count
            owners[work.id] = index
            let states = work.sessions
            let name: String, since: Date, pending: Bool
            switch work {
            case .task(let item):
                name = item.task.title
                since = states.map(\.stateSince).max() ?? item.leaves.map(\.since).min() ?? item.task.modifiedAt
                pending = item.reaching
            case .session(let session):
                name = session.title.isEmpty ? String(localized: "会话") : session.title
                since = session.stateSince
                pending = false
            }
            var entry = Work(id: work.id, name: name, since: since, pending: pending)
            for session in states {
                let state = session.runtimeState
                let running = state.isWorking && state != .known(.delegating) ? 1 : 0
                let delegating = state == .known(.delegating) ? 1 : 0
                let agents = session.runtimeSubagents.count(where: \.isRunning)
                let added = sessionRefs[session.sessionID] == nil
                if added {
                    sessionRefs[session.sessionID] = sessions.count
                    sessions.append(Session(agents: agents))
                }
                let ref = sessionRefs[session.sessionID]!
                entry.sessionRefs.append(ref)
                entry.running += running
                entry.delegating += delegating
                entry.agents += agents
                if state.known == nil { entry.unknown += 1 }
                if let due = session.runtimeUntil {
                    let runningSince = running > 0 ? session.busySince ?? session.stateSince : nil
                    let delegatingSince = delegating > 0 ? session.stateSince : nil
                    entry.runningSince = [entry.runningSince, runningSince].compactMap { $0 }.min()
                    entry.delegatingSince = [entry.delegatingSince, delegatingSince].compactMap { $0 }.min()
                    events[due, default: []].append(Removal(
                        work: index, running: running, delegating: delegating, agents: agents, unknown: 1,
                        startedRunning: runningSince, startedDelegating: delegatingSince, expiredSessions: added ? [ref] : []))
                }
            }
            if entry.pending {
                events[now + CueNow.fastStale, default: []].append(Removal(work: index, pending: true, unknown: 1))
            }
            works.append(entry)
        }
        func owner(_ task: UUID?, _ session: PiSessionState) -> Int? {
            task.flatMap { owners["task/\($0.uuidString)"] } ?? owners["session/\(session.sessionID)"]
        }
        for waiting in source.waiting {
            guard case .session(let session, let task) = waiting else { continue }
            let index = owner(task, session)
            if let index { works[index].held += 1 }
            if let due = session.runtimeUntil {
                events[due, default: []].append(Removal(work: index, asks: 1, visible: waiting.id))
            }
        }
        for reply in source.replies {
            let index = owner(reply.task, reply.session)
            if let index { works[index].held += 1 }
            if let due = reply.session.runtimeUntil {
                events[due, default: []].append(Removal(work: index, reply: 1, visible: reply.id))
            }
        }
        for work in works {
            tally.moving += work.moving
            tally.delegating += work.delegated
            if work.held == 0 {
                for ref in work.sessionRefs { sessions[ref].advancing += 1 }
            }
            if work.unknown > 0 { unconfirmed = true }
        }
        subagents = sessions.reduce(0) { $0 + $1.contribution }
        waiting = source.waiting.map { wait in
            let until: Date? = if case .session(let session, _) = wait { session.runtimeUntil } else { nil }
            return (until, CueNow.wait(wait, name: digest.name))
        }
        dates = events.keys.sorted()[...]
        freezeTimes()
    }

    /// 逆序汇总每台到期之后仍有效的最早起点；每份会话贡献只合并一次，不按会话数量排序或逐期限重扫。
    private mutating func freezeTimes() {
        var running: [Int: Date] = [:], delegating: [Int: Date] = [:]
        for date in dates.reversed() {
            var grouped: [Int: Removal] = [:], markers: [Removal] = []
            for removal in events[date]! {
                guard removal.unknown > 0, let work = removal.work else { markers.append(removal); continue }
                if grouped[work] == nil { grouped[work] = removal } else { grouped[work]!.merge(removal) }
            }
            events[date] = grouped.map { work, removal in
                var removal = removal
                removal.afterRunning = running[work]
                removal.afterDelegating = delegating[work]
                running[work] = [running[work], removal.startedRunning].compactMap { $0 }.min()
                delegating[work] = [delegating[work], removal.startedDelegating].compactMap { $0 }.min()
                return removal
            } + markers
        }
    }

    var items: [CueNow.Item] { works.filter { $0.held == 0 }.map(\.item) }

    mutating func decay(visible items: [CueNow.Item]) -> [CueNow.Decay] {
        let visible = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.slot) })
        shownIDs = Dictionary(uniqueKeysWithValues: items.map { ($0.slot, $0.id) })
        for (index, work) in works.enumerated() {
            if let slot = visible[work.id] { workSlots[index] = slot }
        }
        for removals in events.values {
            for removal in removals {
                guard let work = removal.work, let id = removal.visible, let slot = visible[id] else { continue }
                workSlots[work] = min(workSlots[work] ?? slot, slot)
            }
        }
        var steps: [CueNow.Decay] = []
        while let step = next(visible: visible) { steps.append(step) }
        return steps
    }

    private mutating func next(visible: [String: Int]) -> CueNow.Decay? {
        guard let date = dates.popFirst(), let removals = events.removeValue(forKey: date) else { return nil }
        var changed = Set<Int>(), items: [CueNow.Decay.Change] = []
        for removal in removals {
            tally.asks -= removal.asks
            tally.reply -= removal.reply
            for ref in removal.expiredSessions {
                let before = sessions[ref].contribution
                sessions[ref].agents = 0
                subagents -= before
            }
            if let id = removal.visible, let index = visible[id] {
                items.append(.remove(slot: index))
                shownIDs[index] = nil
            }
            guard let index = removal.work else { continue }
            let before = works[index]
            works[index].running -= removal.running
            works[index].delegating -= removal.delegating
            works[index].agents -= removal.agents
            works[index].held -= removal.asks + removal.reply
            if removal.pending { works[index].pending = false }
            works[index].unknown += removal.unknown
            if removal.unknown > 0 {
                works[index].runningSince = removal.afterRunning
                works[index].delegatingSince = removal.afterDelegating
            }
            let after = works[index]
            tally.moving += after.moving - before.moving
            tally.delegating += after.delegated - before.delegated
            advancing += after.advancing - before.advancing
            if before.held > 0 && after.held == 0 {
                for ref in after.sessionRefs {
                    let contribution = sessions[ref].contribution
                    sessions[ref].advancing += 1
                    subagents += sessions[ref].contribution - contribution
                }
            }
            if workSlots[index] != nil { changed.insert(index) }
        }
        for index in changed.sorted() {
            let work = works[index]
            guard work.held == 0, let slot = workSlots[index] else { continue }
            if shownIDs[slot] == work.id {
                items.append(.update(slot: slot, kind: work.kind, since: work.item.since, subagents: work.item.subagents))
            } else {
                var item = work.item
                item.slot = slot
                items.append(.replace(item))
                shownIDs[slot] = work.id
            }
        }
        let beforeFirst = firstIndex
        while firstIndex < waiting.count, let until = waiting[firstIndex].until, until <= date { firstIndex += 1 }
        let first = firstIndex < waiting.count ? waiting[firstIndex].value : nil
        return CueNow.Decay(at: date, tally: tally, advancing: advancing, subagents: subagents, items: items, first: beforeFirst == firstIndex ? nil : first, replaceFirst: beforeFirst != firstIndex)
    }
}
