import CueStore
import Foundation

/// Cue 自己醒来的一轮在 Cue 页对话里的样子（`CueNoteLog` 里的一行）：这一轮的经过那一行（为什么醒、碰到的各处）与它这一轮说的话。
/// 旧版本写下的动态可能没有经过那一行（只有正文），也可能经过那一行上没有醒来原因（`header` 为 nil）。
nonisolated struct CueNoteRound: Identifiable, Equatable, Sendable {
    /// 经过那一行
    let row: CueMessage?
    /// 这一轮碰到的各处（`CueActivity.touches`）：在跑时挂在这一行下面（`CueTrace`）
    let touches: [CueActivity.Touch]
    /// 为什么醒、叫醒它的那几处（`CueMessage.wake`）
    let header: CueWakeHeader?
    /// 这一轮说的话（动态的正文），从早到晚
    var said: [CueMessage]

    /// `lines`：提醒的那几条记忆的正文（按 id；记忆的正文写下就不变，忘掉的照读）
    init(row: CueMessage, lines: [UUID: String]) {
        header = row.wake.map { CueWakeHeader($0, lines: lines) }
        self.row = row
        touches = CueActivity.touches(row.tools)
        said = []
    }

    init(said: CueMessage) {
        row = nil
        touches = []
        header = nil
        self.said = [said]
    }

    var id: UUID { row?.id ?? said[0].id }
    var date: Date { row?.createdAt ?? said[0].createdAt }
    /// 什么都不显示：没有醒来原因、没说话（旧版本写下的经过）
    var isEmpty: Bool { header == nil && said.isEmpty }

    /// 写在 `date` 的一条动态还接在 `last` 这一节所在的那一格里：没隔 `ChatTime.gap`、没跨天（同时间那一行另起一段的规则）。
    static func continues(_ last: CueNoteRound, at date: Date) -> Bool {
        let end = last.said.last?.createdAt ?? last.date
        return date.timeIntervalSince(end) < ChatTime.gap && Calendar.current.isDate(date, inSameDayAs: end)
    }
}

/// 一轮为什么醒（只画图标，`CueWake.icon`）与叫醒它的那几处：会话、任务的动静各是一处，带当时出了什么事（`kind`，"停下了"）；
/// 提醒是到点的那条记忆。都按写下时的记录（`CueStir`）：名字是当时的，会话、任务之后改名、再动起来都不变；去哪由记录推出，不查库。
nonisolated struct CueWakeHeader: Equatable, Sendable {
    /// 点了去哪（`Workspace.open`；Cue 页这一轮的经过里的一行也用它）。会话的 Pi 会话 id 知道就带上，进会话页少读一次
    enum Target: Equatable, Sendable {
        case session(UUID, sessionID: String?)
        case task(UUID)
        case memory
    }

    struct Place: Equatable, Sendable {
        let title: String
        /// 当时出了什么事；提醒没有
        var kind: CueChange.Kind?
        let target: Target
    }

    let wake: CueWake
    /// 叫醒它的那几处，最新的在前，同一处只留最近那次
    let places: [Place]

    init(_ wake: CueWake, lines: [UUID: String]) {
        self.wake = wake
        switch wake {
        case .sessionActivity(let stirs):
            var seen = Set<String>(), places: [Place] = []
            for stir in stirs.reversed() where seen.insert(stir.session ?? stir.task?.uuidString ?? "").inserted {
                // 更旧版本写下的没有名字（`CueStir.name`）：只说是哪一类
                if let id = stir.session {
                    places.append(Place(
                        title: stir.name ?? "一个会话", kind: stir.kind, target: .session(PiSessionState.recordID(sessionID: id), sessionID: id)))
                } else if let task = stir.task {
                    places.append(Place(title: stir.name ?? "一件任务", kind: stir.kind, target: .task(task)))
                }
            }
            self.places = places
        case .reminder(let ids):
            let first = ids.lazy.compactMap { lines[$0] }.first
            places = first.map { line in
                let title = PiProgress.firstLine(line) ?? line
                return [Place(title: ids.count > 1 ? "\(title) 等 \(ids.count) 条" : title, target: .memory)]
            } ?? []
        case .enabled, .message, .idle:
            places = []
        }
    }
}

extension CueChange.Kind {
    /// 当时出了什么事的一句。
    var verb: String {
        switch self {
        case .settled: "停下了"
        case .waitingForUser: "在等回答"
        case .failed: "出错了"
        case .undelivered: "话没送到"
        case .done: "做完了"
        case .stalled: "子代理卡住了"
        }
    }

    /// 当时出了什么事的图标（Cue 页只提到一处的那一行）：静止的，会话与任务同一种事同一个样子；形状借那时那一处的状态图形（`PiShown.icon`），
    /// 不画那一处此刻的状态——此刻在跑的会话在这里也不动。
    var icon: Icon {
        switch self {
        // 停下时 Cue 在值班，会话是"歇着"
        case .settled: PiShown(status: .resting).icon
        case .waitingForUser: PiShown(status: .asking).icon
        case .failed: PiShown(status: .failed).icon
        case .undelivered: .undelivered
        case .done: .complete
        case .stalled: .subagent
        }
    }
}

extension CueWake {
    /// 为什么醒的一句话（Cue 页没提到哪处的那一行照写；Mac 的运行情况照写）。
    var reason: String {
        switch self {
        case .enabled: "刚启用"
        case .message: "你发来消息"
        case .idle: "空闲时看了一眼"
        case .sessionActivity: "会话有动静"
        case .reminder: "提醒到点"
        }
    }

    /// 醒来原因的图标（Cue 页那一行没提到会话、任务时、Mac 的运行情况）。
    var icon: Icon {
        switch self {
        case .enabled: .wakeEnabled
        case .message: .wakeMessage
        case .sessionActivity: .wakeActivity
        case .idle: .wakeIdle
        case .reminder: .wakeReminder
        }
    }
}
