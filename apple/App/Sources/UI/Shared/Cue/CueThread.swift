import CueStore
import SwiftUI

/// Cue 页一次读到的：最近的对话、对话与"等你"里提到的每件活、在等你的那几条；对话排成的格子与刻度滑条的刻度在读的时候一起推好
/// （不在主线程，滚动时页面重算也不再推一遍）。
nonisolated struct CueThread: Equatable, Sendable {
    let messages: [CueMessage]
    /// 对话与"等你"提到的活（消息上收成一行的引用、结果卡与"等你"里的交付物）。
    let tasks: [UUID: CueTaskRef]
    /// 在等你的（Kit 的 `cueMessagesWaitingForYou` 是唯一的规则）。
    let waiting: [CueMessage]
    let rows: [Row]
    /// 紧挨着上面同一边一颗气泡的气泡（你的话接你的话、Cue 的话接 Cue 的话，中间没隔着时间）：收紧成一串（`CueBubble`）。
    let joined: Set<UUID>
    /// 上面另起一段写时间的格子（`ChatTimeMarker`）：读到的第一格，与离上一格隔了 `ChatTime.gap` 以上或跨了天的。
    /// 换新的分隔自己写着时间，不另写。
    let stamps: [UUID: Date]
    /// 刻度滑条：你的话与换新的地方（`ChatMark`），按 `rows` 的先后。
    let marks: [ChatMark]

    /// 读最近这么多条对话（更早的不在 Cue 页里翻：要找旧事问 Cue）。
    static let limit = 200

    /// `showsSteps`：对话里排不排每一轮的经过（`AppSettings.showsCueSteps`）。
    init(messages: [CueMessage], tasks: [UUID: CueTaskRef], waiting: [CueMessage], showsSteps: Bool) {
        self.messages = messages
        self.tasks = tasks
        self.waiting = waiting
        rows = Self.rows(messages, tasks: tasks, waiting: waiting, showsSteps: showsSteps)
        let stamps = Self.stamps(rows)
        self.stamps = stamps
        joined = Set(zip(rows, rows.dropFirst()).compactMap { above, row in
            row.speaker != nil && row.speaker == above.speaker && stamps[row.id] == nil ? row.id : nil
        })
        marks = ChatMark.enough(rows.compactMap { row in
            switch row {
            case .you(let message): ChatMark(id: message.id, kind: .said, preview: ChatMark.firstLine(message.text))
            case .renewed(let handoff):
                ChatMark(id: handoff.id, kind: .boundary, preview: Dotted("换了新上下文", handoff.createdAt.formatted(date: .omitted, time: .shortened)).visible)
            case .cue, .result, .notes, .process: nil
            }
        })
    }

    static func read(from store: isolated CueStore, showsSteps: Bool) throws -> CueThread {
        let messages = try store.cueMessages(limit: limit)
        let waiting = try store.cueMessagesWaitingForYou()
        let mentioned = Set((messages + waiting).compactMap(\.taskID))
        // 提到的一次取完交付物与步骤进度，不逐件读细节
        let deliverables = try store.deliverables(of: Array(mentioned))
        let progress = try store.subtaskProgress()
        var tasks: [UUID: CueTaskRef] = [:]
        for id in mentioned {
            guard let card = try store.card(id), card.isTask, card.deletedAt == nil else { continue }
            tasks[id] = CueTaskRef(task: card, progress: progress[id], deliverables: deliverables[id] ?? [])
        }
        return CueThread(messages: messages, tasks: tasks, waiting: waiting, showsSteps: showsSteps)
    }

    /// 对话里的一格：你的话、你发起的一轮的经过（这一轮说的话与结果都在它之后）、Cue 的话（第一次提到一件活时下面一行这件活；
    /// 下面挂着交付物的是结果卡，见 `rows`），
    /// 连着的几条动态（含 Cue 自己醒来的那几轮的经过）收成一格，换新的地方一条分隔（点开是交接备忘）。
    /// 还在等你的不在对话里（只在输入框上方的"等你"里，一处），结束了才回到它原来的位置（选了的带着你选的那一项）。
    /// 设置里关了工具步骤时（`AppSettings.showsCueSteps`）不排经过：没有你发起的一轮的经过，动态里只留它说的话；它在做的事只在末尾一行（`CueEnding`）。
    enum Row: Identifiable, Equatable, Sendable {
        case you(CueMessage)
        case cue(CueMessage, task: UUID?)
        /// 挂着交付物的 Cue 的话（结果卡）：从早到晚
        case result(CueMessage, task: UUID, deliverables: [PiPreview])
        case notes([CueMessage])
        /// 你发起的一轮的经过（`CueAuthor.round`）
        case process(CueMessage)
        /// Cue 从这里起换了新上下文：写下的那份交接备忘（`CueAuthor.handoff`）就是这里的全部数据。
        case renewed(CueMessage)

        var id: UUID {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _, _), .renewed(let message), .process(let message): message.id
            case .notes(let group): group[0].id
            }
        }

        var date: Date {
            switch self {
            case .you(let message), .cue(let message, _), .result(let message, _, _), .renewed(let message), .process(let message): message.createdAt
            case .notes(let group): group[0].createdAt
            }
        }

        /// 这一格下面挂的那件活：Cue 第一次提到它的话、结果卡。
        var taskID: UUID? {
            switch self {
            case .cue(_, let task): task
            case .result(_, let task, _): task
            case .you, .notes, .process, .renewed: nil
            }
        }

        /// 在跑的那一轮（`CueLiveRound.round`）在这一格里：它的经过，或收着它的那几条动态。
        func contains(round: UUID) -> Bool {
            switch self {
            case .process(let message): message.id == round
            case .notes(let notes): notes.contains { $0.id == round }
            case .you, .cue, .result, .renewed: false
            }
        }

        /// 气泡在哪一边：你的话靠右，Cue 的话靠左；其余（结果卡、经过、动态、分隔）不是气泡，不与上下的气泡连成一串。
        var speaker: HorizontalEdge? {
            switch self {
            case .you: .trailing
            case .cue: .leading
            case .result, .notes, .process, .renewed: nil
            }
        }
    }

    private static func stamps(_ rows: [Row]) -> [UUID: Date] {
        var stamps: [UUID: Date] = [:]
        var previous: Date?
        let calendar = Calendar.current
        for row in rows {
            defer { previous = row.date }
            if case .renewed = row { continue }
            guard let previous else {
                stamps[row.id] = row.date
                continue
            }
            if row.date.timeIntervalSince(previous) >= ChatTime.gap || !calendar.isDate(row.date, inSameDayAs: previous) { stamps[row.id] = row.date }
        }
        return stamps
    }

    /// 交付物挂在哪句话下面（只此一处）：一件活的 Cue 的话（还在"等你"里的除外）挂上这件活从上一次挂出之后、到这句话为止新发来的交付物
    /// （按发来的时刻切），挂了的就是结果卡——Cue 做完时写下的"「X」做完了"自然是一张。还在"等你"里的不消耗：答完它回到对话里时才挂。
    private static func rows(_ messages: [CueMessage], tasks: [UUID: CueTaskRef], waiting: [CueMessage], showsSteps: Bool) -> [Row] {
        let waiting = Set(waiting.map(\.id))
        var shown = Set<UUID>()
        /// 每件活上一次挂到的时刻
        var hung: [UUID: Date] = [:]
        var rows: [Row] = []
        for message in messages {
            switch message.author.known {
            case .you: rows.append(.you(message))
            case .cue:
                if waiting.contains(message.id) { continue }
                if let id = message.taskID, let ref = tasks[id] {
                    let fresh = ref.deliverables.filter { $0.createdAt <= message.createdAt && $0.createdAt > hung[id, default: .distantPast] }
                    if !fresh.isEmpty {
                        hung[id] = message.createdAt
                        shown.insert(id)
                        rows.append(.result(message, task: id, deliverables: fresh))
                        continue
                    }
                }
                let task = message.taskID.flatMap { tasks[$0] != nil && shown.insert($0).inserted ? $0 : nil }
                rows.append(.cue(message, task: task))
            case .note:
                // 有经过的那条就是它自己醒来那一轮的经过（正文是空的）
                if !showsSteps, message.tools != nil { continue }
                if case .notes(let group) = rows.last { rows[rows.count - 1] = .notes(group + [message]) } else { rows.append(.notes([message])) }
            case .handoff: rows.append(.renewed(message))
            case .round: if showsSteps { rows.append(.process(message)) }
            case nil: break
            }
        }
        return rows
    }
}

/// 对话或"等你"提到的一件活：任务、步骤进度、交付物。提到的卡不在了（删掉、改回灵感）就没有引用，那句话照常显示。
nonisolated struct CueTaskRef: Equatable, Sendable {
    var task: Card
    var progress: TaskProgress?
    /// 全部交付物，从早到晚（`CueStore.deliverables` 是唯一的规则）
    var deliverables: [PiPreview]

    var done: Bool { task.status == .done }
}
