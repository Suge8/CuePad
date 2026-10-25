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

    init(row: CueMessage, names: CueWakeNames) {
        header = row.wake.map { CueWakeHeader($0, names: names) }
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
/// 提醒是到点的那条记忆。名字读的时候查好（`CueWakeNames`）；当时出了什么事与这一处此刻怎样分开——此刻的状态由显示的地方读。
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
        /// 不在了的没有
        var target: Target?
        /// 任务此刻的状态（任务圈）；会话的是 nil
        var task: TaskStatus?

        var sessionID: String? {
            if case .session(_, let sessionID)? = target { sessionID } else { nil }
        }
    }

    let wake: CueWake
    /// 叫醒它的那几处，最新的在前，同一处只留最近那次
    let places: [Place]

    init(_ wake: CueWake, names: CueWakeNames) {
        self.wake = wake
        switch wake {
        case .sessionActivity(let stirs):
            var seen = Set<String>(), places: [Place] = []
            for stir in stirs.reversed() where seen.insert(stir.session ?? stir.task?.uuidString ?? "").inserted {
                if let id = stir.session {
                    let session = names.sessions[id]
                    places.append(Place(
                        title: session?.title ?? "一个会话", kind: stir.kind, target: session.map { .session($0.id, sessionID: $0.sessionID) }))
                } else if let task = stir.task {
                    let title = names.tasks[task]
                    places.append(Place(title: title ?? "一件任务", kind: stir.kind, target: title == nil ? nil : .task(task), task: names.taskStatus[task]))
                }
            }
            self.places = places
        case .reminder(let ids):
            let first = ids.lazy.compactMap { names.lines[$0] }.first
            places = first.map { line in
                let title = PiProgress.firstLine(line) ?? line
                return [Place(title: ids.count > 1 ? "\(title) 等 \(ids.count) 条" : title, target: .memory)]
            } ?? []
        case .enabled, .message, .idle:
            places = []
        }
    }

    /// 当时出了什么事的一句。
    static func verb(_ kind: CueChange.Kind) -> String {
        switch kind {
        case .settled: "停下了"
        case .waitingForUser: "在等回答"
        case .failed: "出错了"
        case .undelivered: "话没送到"
        case .done: "做完了"
        case .stalled: "子代理卡住了"
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

/// Cue 自己醒来的那几轮，叫醒它的会话、任务与提醒此刻叫什么（`CueThread.read` 一次读好，不在主线程）：改了名跟着变，名字不另存。
nonisolated struct CueWakeNames: Equatable, Sendable {
    struct Session: Equatable, Sendable {
        let id: UUID
        let sessionID: String
        let title: String
    }

    /// 按 Pi 的会话 id
    var sessions: [String: Session] = [:]
    var tasks: [UUID: String] = [:]
    var taskStatus: [UUID: TaskStatus] = [:]
    /// 提醒的记忆：正文
    var lines: [UUID: String] = [:]

    static func read(_ wakes: [CueWake], from store: isolated CueStore) throws -> CueWakeNames {
        var sessionIDs: [String] = [], taskIDs = Set<UUID>(), lineIDs: [UUID] = []
        for wake in wakes {
            switch wake {
            case .sessionActivity(let stirs):
                sessionIDs += stirs.compactMap(\.session)
                taskIDs.formUnion(stirs.compactMap(\.task))
            case .reminder(let ids): lineIDs += ids
            case .enabled, .message, .idle: break
            }
        }
        var names = CueWakeNames()
        for (id, item) in try store.piSessions(sessionIDs: sessionIDs) {
            names.sessions[id] = Session(id: item.state.id, sessionID: id, title: item.state.title)
        }
        for id in taskIDs {
            if let card = try store.card(id), card.deletedAt == nil {
                names.tasks[id] = card.title
                names.taskStatus[id] = card.status
            }
        }
        for line in try store.cueLines(lineIDs) { names.lines[line.line.id] = line.line.text }
        return names
    }
}
