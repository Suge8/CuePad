import CueStore
import Foundation

/// 旧版本的经过那一行上可能没有醒来原因（`header` 为 nil）。
nonisolated struct CueNoteRound: Identifiable, Equatable, Sendable {
    let row: CueMessage
    let header: CueWakeHeader?
    let touches: [CueActivity.Touch]

    /// `lines`：到点的那几条定时（按 id；记忆的正文写下就不变，忘掉的照读）
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

/// 连着的几轮里同一处、同一件事、同一个去处的只占一行：字与时刻按最近那次，醒过几次写在字后面。
/// 几处一起叫醒的、补上的定时各是各的事，不并。
nonisolated struct CueNoteFold: Identifiable, Equatable, Sendable {
    /// 从早到晚。
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

/// 都按写下时的记录（`CueStir` 与这一行的 `CueMessage.places`）：名字是当时的，会话、任务之后改名、再动起来都不变；去哪由记录推出，不查库。
nonisolated struct CueWakeHeader: Equatable, Sendable {
    /// 会话的 Pi 会话 id 知道就带上，进会话页少读一次。
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

        /// 会话叫醒的一轮里 Cue 对一件任务做的（经过只记任务，不记它绑的会话）也算落在这一处——它醒来就是为这个会话，
        /// 对别的会话做的（转给另一个会话）才是落在别处。
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
    /// 没记下的（其他版本写来的、写下时已不在的）只说是哪一类。
    func name(session: String) -> String { place(session: session)?.name ?? String(localized: "一个会话") }
    func name(task: UUID) -> String { place(task: task)?.name ?? String(localized: "一件任务") }
}

nonisolated extension CuePlace {
    var progress: TaskProgress? { steps.map { TaskProgress(done: $0.done, total: $0.total) } }
}

extension CueChange.Kind {
    /// 形状借那时那一处的状态图形（`SessionShown.icon`），不画那一处此刻的状态——此刻在跑的会话在这里也不动。
    var icon: Icon {
        switch self {
        // 停下是会话这一轮跑完：借在跑的心电线静止形（省略号是"歇着"那个此刻的状态，单看不知所云）
        case .settled: .session
        case .waitingForUser: SessionShown(status: .asking).icon
        case .failed: SessionShown(status: .failed(.other)).icon
        case .undelivered: .undelivered
        case .done: .complete
        // 等子代理那两颗点，小点空心：交出去的没动静了（与"停下了"的省略号形状不同族）
        case .stalled: .relayStalled
        }
    }

    /// 经过是历史，平时一律灰；只有还没处理的那一条着这件事的颜色（`CueNoteLog` 的 `openTint`），已经处理过的不再像在报警。做完、停下了从不着色。
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
