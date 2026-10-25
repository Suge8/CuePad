import CueStore
import SwiftUI

/// Cue 页一次读到的：最近的对话、对话与"等你"里提到的每件活、在等你的那几条、待回复的会话；对话排成的格子与刻度滑条的刻度在读的时候一起推好
/// （不在主线程，滚动时页面重算也不再推一遍）。
nonisolated struct CueThread: Equatable, Sendable {
    /// 最近的对话，从早到晚；前面另带上早于它问、在它这段时间里答了的提问（`CueStore.cueQuestionsAnswered`）：
    /// 你的回答在读到的范围里，它引用的那条提问也要在，点引用才回得去。
    let messages: [CueMessage]
    /// 对话与"等你"提到的活（消息上收成一行的引用）。
    let tasks: [UUID: CueTaskRef]
    /// 等你（Cue 的提问与会话在问的，同进展页等你列，`TaskBoard.waits`），等得最久的在前；点名要露的那件在最前（`leading`）。
    let waiting: [TaskBoard.Wait]
    /// 待回复的会话（`CueStore.sessionsAwaitingReply`），等得最久的在前：等你卡上方那条提示（`CueReplyTip`）。
    let replies: [PiSessionState]
    /// Cue 点名要你看的图（`CueMessage.shots`：提问的与做完的结果），按消息的 id：只有点了名、那一份还在的
    let shots: [UUID: [CueShown]]
    let rows: [Row]
    /// 紧挨着上面同一边一颗气泡的气泡（你的话接你的话、Cue 的话接 Cue 的话，中间没隔着时间）：收紧成一串（`CueBubble`）。
    let joined: Set<UUID>
    /// 上面另起一段写时间的格子（`ChatTimeMarker`）：读到的第一格，与离上一格隔了 `ChatTime.gap` 以上或跨了天的。
    /// 换新的分隔自己写着时间，不另写。
    let stamps: [UUID: Date]
    /// 刻度滑条：你的话与换新的地方（`ChatMark`），按 `rows` 的先后。
    let marks: [ChatMark]
    /// 还没读的 Cue 的话（Kit 的 `cueUnread` 是唯一的规则）。
    let unread: Set<UUID>

    /// 读最近这么多条对话（更早的不在 Cue 页里翻：要找旧事问 Cue）。
    static let limit = 200

    /// `lines`：Cue 被提醒叫醒的那几轮，到点的记忆的正文（按 id）。
    init(
        messages: [CueMessage], tasks: [UUID: CueTaskRef], waiting: [TaskBoard.Wait], replies: [PiSessionState], shots: [UUID: [CueShown]],
        unread: Set<UUID>, lines: [UUID: String]
    ) {
        self.messages = messages
        self.tasks = tasks
        self.waiting = waiting
        self.replies = replies
        self.shots = shots
        self.unread = unread
        let rows = Self.rows(messages, tasks: tasks, waiting: Set(waiting.compactMap(\.message?.id)), shots: shots, lines: lines)
        self.rows = rows
        let stamps = Self.stamps(rows)
        self.stamps = stamps
        joined = Set(zip(rows, rows.dropFirst()).compactMap { above, row in
            row.speaker != nil && row.speaker == above.speaker && stamps[row.id] == nil ? row.id : nil
        })
        marks = ChatMark.enough(rows.compactMap { row in
            switch row {
            case .you(let message): ChatMark(id: message.id, kind: .said, preview: ChatMark.firstLine(message.text))
            case .answer(let question, _): ChatMark(id: row.id, kind: .said, preview: ChatMark.firstLine(question.answer ?? ""))
            case .cue, .result, .notes, .process: nil
            }
        })
    }

    /// `asking`：要露在"等你"卡里的那条 Cue 的提问（`Workspace.cueAsking`：从任务看板点进来），见 `leading`。
    static func read(from store: isolated CueStore, asking: UUID? = nil) throws -> CueThread {
        let recent = try store.cueMessages(limit: limit)
        let messages = try store.cueQuestionsAnswered(outside: recent) + recent
        // 提到的一次取完子任务进度，不逐件读细节
        let progress = try store.subtaskProgress()
        let waits = leading(try TaskBoard.waits(try store.cueWaiting(), from: store) { task in
            TaskBoard.Item(task: task, steps: progress[task.id])
        }, asking: asking)
        let waiting = waits.compactMap(\.message)
        let mentioned = Set((messages + waiting).compactMap(\.taskID))
        var tasks: [UUID: CueTaskRef] = [:]
        for id in mentioned {
            guard let card = try store.card(id), card.isTask, card.deletedAt == nil else { continue }
            tasks[id] = CueTaskRef(task: card, progress: progress[id])
        }
        let pointed = (messages + waiting).filter { !$0.shots.isEmpty }
        let previews = try store.previews(Set(pointed.flatMap { $0.shots.map(\.preview) }))
        var shots: [UUID: [CueShown]] = [:]
        for message in pointed {
            let shown = message.shots.compactMap { shot in
                previews[shot.preview].map { CueShown(preview: $0, look: shot.look) }
            }
            if !shown.isEmpty { shots[message.id] = shown }
        }
        let reminded = messages.flatMap { message -> [UUID] in if case .reminder(let ids)? = message.wake { ids } else { [] } }
        return CueThread(
            messages: messages, tasks: tasks, waiting: waits, replies: try store.sessionsAwaitingReply(), shots: shots, unread: Set(try store.cueUnread()),
            lines: Dictionary(try store.cueLines(reminded).map { ($0.line.id, $0.line.text) }) { first, _ in first })
    }

    /// "等你"卡露的先后：点名要露的那条（`asking`）还在等就排到最前，其余照旧等得最久的在前。卡先露最前的那件。
    static func leading(_ waiting: [TaskBoard.Wait], asking: UUID?) -> [TaskBoard.Wait] {
        guard let asking, let index = waiting.firstIndex(where: { $0.message?.id == asking }), index > 0 else { return waiting }
        var ordered = waiting
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    /// 对话里的一格：你的话、你发起的一轮的经过（碰到的各处，`CueActivity.touches`；一处都没碰的一轮没有这一格；这一轮说的话与结果都在它之后）、Cue 的话（第一次提到一件活时下面一行这件活；
    /// 做完的结果点了名的图是结果卡，见 `rows`），
    /// 连着的几轮 Cue 自己醒来（每轮是它的经过那一行与它说的话，`CueNoteRound`，每轮一行旁注 `CueNoteLog`）收成一格，隔了 `ChatTime.gap` 以上或跨了天另起一格。
    /// 还在等你的提问不在对话里，都在输入框上方的"等你"卡里（同一问同屏一处），结束了回到 Cue 的一句；你答了的，答的那一刻另有一格你的回答（`answer`）。
    /// 它在做的事，自己醒来的一轮写在动态里那一节下面，你发起的一轮写在它的经过里，还没有经过时在末尾一行（`CueEnding`）。
    enum Row: Identifiable, Equatable, Sendable {
        case you(CueMessage)
        /// 你对一条提问的回答（选的那一项，`CueMessage.answer`；更旧版本存下的另外一句照原文），排在答的那一刻（`answeredAt`）；数据就是那条提问本身，
        /// 收起、撤回的没有这一格。问的那句总在对话里（`messages`）：紧挨在上面时不带引用（`quoted` 为 false，问句同屏只留一份），
        /// 隔开了才在字上面引一行它问的是什么，点了跳回去
        case answer(CueMessage, quoted: Bool)
        case cue(CueMessage, task: UUID?)
        /// 点名了图的结果（结果卡）：图在 `CueThread.shots`
        case result(CueMessage, task: UUID)
        case notes([CueNoteRound])
        /// 你发起的一轮的经过（`CueAuthor.round`）：碰到的各处（`CueTrace`），读的时候推好
        case process(CueMessage, touches: [CueActivity.Touch])

        var id: UUID {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _), .process(let message, _): message.id
            case .answer(let question, _): Self.answerID(of: question.id)
            case .notes(let rounds): rounds[0].id
            }
        }

        var date: Date {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _), .process(let message, _): message.createdAt
            case .answer(let question, _): question.answeredAt ?? question.createdAt
            case .notes(let rounds): rounds[0].date
            }
        }

        /// 回答那一格的 id：由提问的 id 推出（不另存），与提问那一格不同。
        static func answerID(of question: UUID) -> UUID {
            var bytes = question.uuid
            bytes.0 ^= 0xA5
            return UUID(uuid: bytes)
        }

        /// 这一格下面挂的那件活：Cue 第一次提到它的话、结果卡。
        var taskID: UUID? {
            switch self {
            case .cue(_, let task): task
            case .result(_, let task): task
            case .you, .answer, .notes, .process: nil
            }
        }

        /// 在跑的那一轮（`CueLiveRound.round`）在这一格里：你发起的一轮的经过，或动态里它那一节（醒来时就写下了）。
        func contains(round: UUID) -> Bool {
            switch self {
            case .process(let message, _): message.id == round
            case .notes(let rounds): rounds.contains { $0.row?.id == round }
            case .you, .answer, .cue, .result: false
            }
        }

        /// 气泡在哪一边：你的话靠右，Cue 的话靠左；其余（结果卡、经过、醒来记录、分隔）不是气泡，不与上下的气泡连成一串。
        var speaker: HorizontalEdge? {
            switch self {
            case .you, .answer: .trailing
            case .cue: .leading
            case .result, .notes, .process: nil
            }
        }
    }

    private static func stamps(_ rows: [Row]) -> [UUID: Date] {
        var stamps: [UUID: Date] = [:]
        var previous: Date?
        let calendar = Calendar.current
        for row in rows {
            defer { previous = row.date }
            guard let previous else {
                stamps[row.id] = row.date
                continue
            }
            if row.date.timeIntervalSince(previous) >= ChatTime.gap || !calendar.isDate(row.date, inSameDayAs: previous) { stamps[row.id] = row.date }
        }
        return stamps
    }

    /// 回答按答的那一刻插进对话（`answer`）：排在那一刻之前最近的那格之后，与会话里的作答、预览卡同一条规则（`PiChat.entries`）。
    /// 结果卡：关联一件活、不是提问、点名了图（`shots`，Cue 做完时挑的最终成果）的 Cue 的话；只挂点名的那几张，这件活发到手机的其余文件在它的会话里。
    /// 提问的图跟着提问那一格（`CueSays`）。
    private static func rows(
        _ messages: [CueMessage], tasks: [UUID: CueTaskRef], waiting: Set<UUID>, shots: [UUID: [CueShown]], lines: [UUID: String]
    ) -> [Row] {
        // 同一毫秒答的按问的先后（`messages` 的顺序）
        var answers = messages.enumerated().filter { $0.element.answer != nil && $0.element.answeredAt != nil }
            .sorted { ($0.element.answeredAt!, $0.offset) < ($1.element.answeredAt!, $1.offset) }.map(\.element)[...]
        var shown = Set<UUID>()
        var rows: [Row] = []
        func placeAnswers(before time: Date?) {
            while let next = answers.first, time.map({ next.answeredAt! < $0 }) ?? true {
                let follows = if case .cue(let asked, _) = rows.last { asked.id == next.id } else { false }
                rows.append(.answer(next, quoted: !follows))
                answers.removeFirst()
            }
        }
        for message in messages {
            placeAnswers(before: message.createdAt)
            switch message.author.known {
            case .you: rows.append(.you(message))
            case .cue:
                if waiting.contains(message.id) { continue }
                if message.choices == nil, shots[message.id] != nil, let id = message.taskID, tasks[id] != nil {
                    shown.insert(id)
                    rows.append(.result(message, task: id))
                    continue
                }
                let task = message.taskID.flatMap { tasks[$0] != nil && shown.insert($0).inserted ? $0 : nil }
                rows.append(.cue(message, task: task))
            case .note:
                // 没有正文的是一轮的经过（为什么醒、做了什么），开一节；有正文的是这一轮说的话，接在最近那一节后面
                var group: [CueNoteRound] = []
                if case .notes(let open) = rows.last, let last = open.last, CueNoteRound.continues(last, at: message.createdAt) {
                    group = open
                    rows.removeLast()
                }
                if message.text.isEmpty {
                    group.append(CueNoteRound(row: message, lines: lines))
                } else if group.isEmpty {
                    group = [CueNoteRound(said: message)]
                } else {
                    group[group.count - 1].said.append(message)
                }
                rows.append(.notes(group))
            case .round:
                let touches = CueActivity.touches(message.tools)
                if !touches.isEmpty { rows.append(.process(message, touches: touches)) }
            // 认不出的（旧版本写下的交接备忘、更新版本的新种类）不列
            case nil: break
            }
        }
        placeAnswers(before: nil)
        // 旧版本写下的经过（没有醒来原因）又没说话的那一节什么都不剩
        return rows.compactMap { row in
            guard case .notes(let rounds) = row else { return row }
            let shown = rounds.filter { !$0.isEmpty }
            return shown.isEmpty ? nil : .notes(shown)
        }
    }
}

/// 对话或"等你"提到的一件活：任务与子任务进度。提到的卡不在了（删掉）就没有引用，那句话照常显示。
nonisolated struct CueTaskRef: Equatable, Sendable {
    var task: Card
    var progress: TaskProgress?

    var done: Bool { task.status == .done }
}

/// Cue 点名要你看的一张图：发到手机的那一份与看它的什么（`CueShot`）。
nonisolated struct CueShown: Identifiable, Equatable, Sendable {
    let preview: PiPreview
    let look: String
    var id: UUID { preview.id }
}

nonisolated extension TaskBoard.Wait {
    /// Cue 的提问；会话在问的是 nil。
    var message: CueMessage? {
        if case .message(let message, _) = wait { message } else { nil }
    }
}
