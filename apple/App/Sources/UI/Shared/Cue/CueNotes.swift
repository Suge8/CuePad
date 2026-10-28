import CueStore
import Foundation

/// Cue 自己醒来的一轮在 Cue 页对话里的样子（`CueNoteLog` 里的一行）：这一轮的经过那一行——为什么醒、叫醒它的各处（`header`）与它做了什么（`touches`）。
/// 这一轮不写话：那一行的去处只从它做的动作推出（`outcome`）。旧版本的经过那一行上可能没有醒来原因（`header` 为 nil）。
nonisolated struct CueNoteRound: Identifiable, Equatable, Sendable {
    let row: CueMessage
    /// 为什么醒、叫醒它的那几处（`CueMessage.wake`）
    let header: CueWakeHeader?
    /// 这一轮碰到的各处（`CueActivity.touches`），按第一次碰到的先后
    let touches: [CueActivity.Touch]

    /// `lines`：到点的那几条定时（按 id；记忆的正文写下就不变，忘掉的照读）
    init(row: CueMessage, lines: [UUID: CueMemoryLine]) {
        header = row.wake.map { CueWakeHeader($0, in: row, lines: lines) }
        touches = CueActivity.touches(row.tools)
        self.row = row
    }

    var id: UUID { row.id }
    var date: Date { row.createdAt }
    /// 什么都不显示：没有醒来原因、也没做什么（旧版本写下的经过）
    var isEmpty: Bool { header == nil && touches.isEmpty }

    /// 这一轮定下的去处：碰到的各处里最要紧的那一步（`CueActivity.outcomeRank`）；什么都没做（或还在想）为 nil。
    var outcome: CueActivity.Touch? {
        touches.min { CueActivity.outcomeRank($0.kind) < CueActivity.outcomeRank($1.kind) }
    }

    /// 写在 `date` 的一轮还接在 `last` 这一节所在的那一格里：没隔 `ChatTime.gap`、没跨天（同时间那一行另起一段的规则）。
    static func continues(_ last: CueNoteRound, at date: Date) -> Bool {
        date.timeIntervalSince(last.date) < ChatTime.gap && Calendar.current.isDate(date, inSameDayAs: last.date)
    }
}

/// 一轮为什么醒（只画图标，`CueWake.icon`）与叫醒它的那几处：会话、任务的动静各是一处，带当时出了什么事（`kind`，"停下了"）；
/// 定时是到点的那条定时（挂在任务上的点了开那件任务，错过后补上的带一句事实）。都按写下时的记录（`CueStir` 与这一行的 `CueMessage.places`）：名字是当时的，会话、任务之后改名、再动起来都不变；
/// 去哪由记录推出，不查库。
nonisolated struct CueWakeHeader: Equatable, Sendable {
    /// 点了去哪（`Workspace.open`；Cue 页这一轮的经过里的一行也用它）。会话的 Pi 会话 id 知道就带上，进会话页少读一次
    enum Target: Hashable, Sendable {
        case session(UUID, sessionID: String?)
        case task(UUID)
        case schedules
    }

    struct Place: Equatable, Sendable {
        let title: String
        /// 当时出了什么事；定时没有
        var kind: CueChange.Kind?
        let target: Target
        /// 定时错过了、这一轮才补上：本该几点、几点补上
        var missed: CueScheduled.Last?

        /// 去处 `touch` 落在这一处上、且是这一处的去处（说话、留给你、做完、收掉）时返回它的种类；否则 nil。
        /// 落在这一处：同一个会话或任务；会话叫醒的一轮里 Cue 对一件任务做的（经过只记任务，不记它绑的会话）也算——它醒来就是为这个会话，
        /// 对别的会话做的（转给另一个会话）才是落在别处。
        func settled(by touch: CueActivity.Touch) -> PiChatMessage.Tools.Kind? {
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
    /// 叫醒它的那几处，最新的在前，同一处只留最近那次
    let places: [Place]

    /// `row`：这一轮的经过那一行（叫醒它的那几处当时叫什么记在它上面）。
    init(_ wake: CueWake, in row: CueMessage, lines: [UUID: CueMemoryLine]) {
        self.wake = wake
        switch wake {
        case .sessionActivity(let stirs):
            var seen = Set<String>(), places: [Place] = []
            for stir in stirs.reversed() where seen.insert(stir.session ?? stir.task?.uuidString ?? "").inserted {
                if let id = stir.session {
                    places.append(Place(
                        title: row.name(session: id), kind: stir.kind, target: .session(PiSessionState.recordID(sessionID: id), sessionID: id)))
                } else if let task = stir.task {
                    places.append(Place(title: row.name(task: task), kind: stir.kind, target: .task(task)))
                }
            }
            self.places = places
        case .schedule(let fires):
            places = fires.lazy.compactMap { fire in lines[fire.line].map { (fire, $0) } }.first.map { fire, line in
                let title = PiProgress.gist(line.text)
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
    /// 写下时提到的那一处叫什么（`places`）；没记下的（其他版本写来的、写下时已不在的）只说是哪一类。
    func name(session: String) -> String { place(session: session)?.name ?? String(localized: "一个会话") }
    func name(task: UUID) -> String { place(task: task)?.name ?? String(localized: "一件任务") }
}

nonisolated extension CuePlace {
    /// 任务圈按它分段（`TaskRingView`）
    var progress: TaskProgress? { steps.map { TaskProgress(done: $0.done, total: $0.total) } }
}

extension CueChange.Kind {
    /// 当时出了什么事的图标（Cue 页只提到一处的那一行）：静止的、灰的，会话与任务同一种事同一个样子，只靠形状分；
    /// 形状借那时那一处的状态图形（`PiShown.icon`），不画那一处此刻的状态——此刻在跑的会话在这里也不动。
    var icon: Icon {
        switch self {
        // 停下是会话这一轮跑完：借在跑的心电线静止形（省略号是"歇着"那个此刻的状态，单看不知所云）
        case .settled: .session
        case .waitingForUser: PiShown(status: .asking).icon
        case .failed: PiShown(status: .failed(.other)).icon
        case .undelivered: .undelivered
        case .done: .complete
        // 等子代理那两颗点，小点空心：交出去的没动静了（与"停下了"的省略号形状不同族）
        case .stalled: .relayStalled
        }
    }

    /// 这件事此刻还没处理：那一处还停在当时那个样子（还在等你回答、还出着错、话还没送到、还在等卡住的子代理）。
    /// 经过是历史，平时一律灰；只有还没处理的那一条着这件事的颜色（`CueNoteLog` 的 `openTint`），已经处理过的不再像在报警。做完、停下了从不着色。
    func isUnresolved(_ status: PiShown.Status, session: PiSessionState, since: Date) -> Bool {
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
    /// 为什么醒的一句话（Cue 页没提到哪处的那一行照写；Mac 的运行情况照写）。
    var reason: String {
        switch self {
        case .enabled: String(localized: "刚启用")
        case .message: String(localized: "你发来消息")
        case .idle: String(localized: "空闲时看了一眼")
        case .sessionActivity: String(localized: "会话有动静")
        case .schedule: String(localized: "定时到点")
        }
    }

    /// 醒来原因的图标（Cue 页那一行没提到会话、任务时、Mac 的运行情况）。
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
