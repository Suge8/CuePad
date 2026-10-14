import CueStore
import Foundation

/// Cue 页一次读到的：最近的对话、对话与"等你"里提到的每件活、在等你的那几条；对话排成的格子与刻度滑条的刻度在读的时候一起推好
/// （不在主线程，滚动时页面重算也不再推一遍）。
nonisolated struct CueThread: Equatable, Sendable {
    let messages: [CueMessage]
    /// 对话与"等你"提到的活（消息上收成一行的引用、"等你"的证据缩略图）。
    let tasks: [UUID: CueTaskRef]
    /// 在等你的（Kit 的 `cueMessagesWaitingForYou` 是唯一的规则）。
    let waiting: [CueMessage]
    let rows: [Row]
    /// 刻度滑条：你的话与换新的地方（`ChatMark`），按 `rows` 的先后。
    let marks: [ChatMark]

    /// 读最近这么多条对话（更早的不在 Cue 页里翻：要找旧事问 Cue）。
    static let limit = 200

    init(messages: [CueMessage], tasks: [UUID: CueTaskRef], waiting: [CueMessage]) {
        self.messages = messages
        self.tasks = tasks
        self.waiting = waiting
        rows = Self.rows(messages, tasks: tasks, waiting: waiting)
        marks = ChatMark.enough(rows.compactMap { row in
            switch row {
            case .you(let message): ChatMark(id: message.id, kind: .said, preview: ChatMark.firstLine(message.text))
            case .renewed(let handoff):
                ChatMark(id: handoff.id, kind: .boundary, preview: "换了新上下文 · \(handoff.createdAt.formatted(date: .omitted, time: .shortened))")
            case .cue, .notes: nil
            }
        })
    }

    static func read(from store: isolated CueStore) throws -> CueThread {
        let messages = try store.cueMessages(limit: limit)
        let waiting = try store.cueMessagesWaitingForYou()
        let mentioned = Set((messages + waiting).compactMap(\.taskID))
        // 提到的一次取完预览与步骤进度，不逐件读细节
        let previews = try store.previews(ofTasks: Array(mentioned))
        let progress = try store.subtaskProgress()
        var tasks: [UUID: CueTaskRef] = [:]
        for id in mentioned {
            guard let card = try store.card(id), card.isTask, card.deletedAt == nil else { continue }
            tasks[id] = CueTaskRef(task: card, progress: progress[id], previews: CueTaskRef.newest(previews[id]))
        }
        return CueThread(messages: messages, tasks: tasks, waiting: waiting)
    }

    /// 对话里的一格：你的话、Cue 的话（第一次提到一件活时下面一行这件活），连着的几条动态收成一格，换新的地方一条分隔（点开是交接备忘）。
    /// 还在等你的不在对话里（只在输入框上方的"等你"里，一处），结束了才回到它原来的位置（选了的带着你选的那一项）。
    enum Row: Identifiable, Equatable, Sendable {
        case you(CueMessage)
        case cue(CueMessage, task: UUID?)
        case notes([CueMessage])
        /// Cue 从这里起换了新上下文：写下的那份交接备忘（`CueAuthor.handoff`）就是这里的全部数据。
        case renewed(CueMessage)

        var id: UUID {
            switch self {
            case .you(let message), .cue(let message, _), .renewed(let message): message.id
            case .notes(let group): group[0].id
            }
        }
    }

    #if os(macOS)
    /// 最近一次换新写下的交接备忘（"运行情况"读）。
    var lastHandoff: CueMessage? { messages.last { $0.author == .known(.handoff) } }
    #endif

    private static func rows(_ messages: [CueMessage], tasks: [UUID: CueTaskRef], waiting: [CueMessage]) -> [Row] {
        let waiting = Set(waiting.map(\.id))
        var shown = Set<UUID>()
        var rows: [Row] = []
        for message in messages {
            switch message.author.known {
            case .you: rows.append(.you(message))
            case .cue:
                if waiting.contains(message.id) { continue }
                let task = message.taskID.flatMap { tasks[$0] != nil && shown.insert($0).inserted ? $0 : nil }
                rows.append(.cue(message, task: task))
            case .note:
                if case .notes(let group) = rows.last { rows[rows.count - 1] = .notes(group + [message]) } else { rows.append(.notes([message])) }
            case .handoff: rows.append(.renewed(message))
            case nil: break
            }
        }
        return rows
    }
}

/// 对话或"等你"提到的一件活：任务、步骤进度、各步骤会话发来看的文件。
nonisolated struct CueTaskRef: Equatable, Sendable {
    var task: Card
    var progress: TaskProgress?
    /// 新的在前，至多 `previewLimit` 份（"等你"放全部：验收看的就是它们）。提到的卡不在了（删掉、改回灵感）就没有引用，那句话照常显示。
    var previews: [PiPreview]

    static let previewLimit = 4

    /// `previews(ofTasks:)` 给的是从早到晚：取最新的 `previewLimit` 份，新的在前。
    static func newest(_ previews: [PiPreview]?) -> [PiPreview] { Array((previews ?? []).suffix(previewLimit).reversed()) }

    var done: Bool { task.status == .done }
}
