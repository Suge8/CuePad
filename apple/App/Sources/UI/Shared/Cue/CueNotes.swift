import CueStore
import Foundation

nonisolated struct CueNoteRound: Identifiable, Equatable, Sendable {
    let row: CueMessage
    let header: CueWakeHeader?
    let touches: [CueActivity.Touch]

    init(row: CueMessage, lines: [UUID: CueMemoryLine]) {
        header = row.wake.map { CueWakeHeader($0, in: row, lines: lines) }
        touches = CueActivity.touches(row.tools)
        self.row = row
    }

    var id: UUID { row.id }
    var date: Date { row.createdAt }
    var isEmpty: Bool { header == nil && touches.isEmpty }

    var outcome: CueActivity.Touch? {
        touches.min { CueActivity.outcomeRank($0.kind) < CueActivity.outcomeRank($1.kind) }
    }
}

nonisolated struct CueNoteFold: Identifiable, Equatable, Sendable {
    let rounds: [CueNoteRound]

    var id: UUID { rounds[0].id }
    var last: CueNoteRound { rounds[rounds.count - 1] }

    private enum Key: Hashable {
        case place(CueWakeHeader.Target, CueChange.Kind?, ChatMessage.Tools.Kind?, String?)
        case idle
        case own(UUID)

        init(_ round: CueNoteRound) {
            let places = round.header?.places ?? []
            if places.count == 1, places[0].missed == nil {
                self = .place(places[0].target, places[0].kind, round.outcome?.kind, round.outcome?.name)
            } else if round.outcome == nil, round.header?.wake == .idle {
                self = .idle
            } else {
                self = .own(round.id)
            }
        }
    }

    static func folds(_ rounds: [CueNoteRound]) -> [CueNoteFold] {
        var groups: [Key: [CueNoteRound]] = [:]
        for round in rounds { groups[Key(round), default: []].append(round) }
        return groups.values.map(CueNoteFold.init).sorted { ($0.last.date, $0.id.uuidString) < ($1.last.date, $1.id.uuidString) }
    }
}

nonisolated struct CueWakeHeader: Equatable, Sendable {
    enum Target: Hashable, Sendable {
        case session(UUID, sessionID: String?)
        case task(UUID)
        case schedules
    }

    struct Place: Equatable, Sendable {
        let title: String
        var kind: CueChange.Kind?
        let target: Target
        var missed: CueScheduled.Last?

        func titled(_ title: String) -> Place { Place(title: title, kind: kind, target: target, missed: missed) }

        func settled(by touch: CueActivity.Touch) -> ChatMessage.Tools.Kind? {
            guard [.talk, .leave, .done, .stop].contains(touch.kind) else { return nil }
            let here = switch target {
            case .session(let id, _): touch.session.map { $0 == id } ?? (touch.task != nil)
            case .task(let id): touch.task == id
            case .schedules: false
            }
            return here ? touch.kind : nil
        }
    }

    let wake: CueWake
    let places: [Place]

    init(_ wake: CueWake, in row: CueMessage, lines: [UUID: CueMemoryLine]) {
        self.wake = wake
        switch wake {
        case .sessionActivity(let stirs):
            var seen = Set<String>(), places: [Place] = []
            for stir in stirs.reversed() where seen.insert(stir.session ?? stir.task?.uuidString ?? "").inserted {
                if let id = stir.session {
                    places.append(Place(
                        title: row.name(session: id), kind: stir.kind, target: .session(SessionState.recordID(sessionID: id), sessionID: id)))
                } else if let task = stir.task {
                    places.append(Place(title: row.name(task: task), kind: stir.kind, target: .task(task)))
                }
            }
            self.places = places
        case .schedule(let fires):
            places = fires.lazy.compactMap { fire in lines[fire.line].map { (fire, $0) } }.first.map { fire, line in
                let title = SessionProgress.gist(line.text)
                let last = CueScheduled.Last(due: fire.due, at: row.createdAt)
                return [Place(
                    title: fires.count > 1 ? String(localized: "\(title) 等 \(fires.count) 条") : title, target: line.task.map(Target.task) ?? .schedules,
                    missed: last.late ? last : nil)]
            } ?? []
        case .enabled, .message, .idle:
            places = []
        }
    }
}

nonisolated extension CueMessage {
    func name(session: String) -> String { place(session: session)?.name ?? String(localized: "一个会话") }
    func name(task: UUID) -> String { place(task: task)?.name ?? String(localized: "一件任务") }
}

nonisolated extension CuePlace {
    var progress: TaskProgress? { steps.map { TaskProgress(done: $0.done, total: $0.total) } }
}

extension CueChange.Kind {
    var icon: Icon {
        switch self {
        case .settled: .session
        case .waitingForUser: SessionShown(status: .asking).icon
        case .failed: SessionShown(status: .failed(.other)).icon
        case .undelivered: .undelivered
        case .done: .complete
        case .stalled: .relayStalled
        }
    }

    func isUnresolved(_ status: SessionShown.Status, session: SessionState, since: Date) -> Bool {
        guard session.stateSince <= since else { return false }
        return switch self {
        case .waitingForUser: status == .asking
        case .failed: if case .failed = status { true } else { false }
        case .undelivered: if case .delivery(.failed) = status { true } else { false }
        case .stalled:
            session.stallsAt.map { $0 <= since } ?? false
        case .settled, .done: false
        }
    }
}

extension CueWake {
    var reason: String {
        switch self {
        case .enabled: String(localized: "刚启用")
        case .message: String(localized: "你发来消息")
        case .idle: String(localized: "空闲时看了一眼")
        case .sessionActivity: String(localized: "会话有动静")
        case .schedule: String(localized: "定时到点")
        }
    }

    var icon: Icon {
        switch self {
        case .enabled: .wakeEnabled
        case .message: .wakeMessage
        case .sessionActivity: .wakeActivity
        case .idle: .wakeIdle
        case .schedule: .schedule
        }
    }
}
