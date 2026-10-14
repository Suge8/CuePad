import CueStore
import Foundation

/// Cue 页一次读到的：最近的对话、对话与"等你"里提到的每件活、在等你的那几条、跟进中的每件活此刻的样子。
nonisolated struct CueThread: Equatable, Sendable {
    var messages: [CueMessage]
    /// 对话与"等你"提到的活（消息上收成一行的引用、"等你"的证据缩略图）。
    var tasks: [UUID: CueTaskRef]
    /// 在等你的（Kit 的 `cueMessagesWaitingForYou` 是唯一的规则）。
    var waiting: [CueMessage]
    /// 跟进中的（`cueBoard`）：输入框上方的托盘，每件一张实时卡片。
    var board: [CueLiveTask]

    /// 读最近这么多条对话（更早的不在 Cue 页里翻：要找旧事问 Cue）。
    static let limit = 200

    static func read(from store: isolated CueStore) throws -> CueThread {
        let messages = try store.cueMessages(limit: limit)
        let waiting = try store.cueMessagesWaitingForYou()
        let mentioned = Set((messages + waiting).compactMap(\.taskID))
        let items = try store.cueBoard()
        // 提到的与跟进中的一次取完预览与步骤进度，不逐件读细节
        let previews = try store.previews(ofTasks: Array(mentioned.union(items.map(\.id))))
        let progress = try store.subtaskProgress()
        var tasks: [UUID: CueTaskRef] = [:]
        for id in mentioned {
            guard let card = try store.card(id), card.isTask, card.deletedAt == nil else { continue }
            tasks[id] = CueTaskRef(task: card, progress: progress[id], previews: CueTaskRef.newest(previews[id]))
        }
        let board = items.map { CueLiveTask(item: $0, preview: previews[$0.id]?.last) }
        return CueThread(messages: messages, tasks: tasks, waiting: waiting, board: board)
    }

    /// 对话里的一格：你的话、Cue 的话（第一次提到一件活时下面一行这件活），连着的几条动态收成一格；交接备忘不显示。
    /// 还在等你的不在对话里（只在输入框上方的"等你"里，一处），结束了才回到它原来的位置（选了的带着你选的那一项）。
    enum Row: Identifiable, Equatable {
        case you(CueMessage)
        case cue(CueMessage, task: UUID?)
        case notes([CueMessage])

        var id: UUID {
            switch self {
            case .you(let message), .cue(let message, _): message.id
            case .notes(let group): group[0].id
            }
        }
    }

    var rows: [Row] {
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
            case .handoff, nil: break
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

/// 跟进中的一件活此刻的样子（托盘里的实时卡片）：看板上的那一项（在做的那一步、它的会话、是不是正在开会话）与最近一份预览。
nonisolated struct CueLiveTask: Equatable, Sendable, Identifiable {
    var item: CueBoardItem
    var preview: PiPreview?

    var id: UUID { item.id }
}

/// "你不在时"：上次离开 Cue 页之后，Cue 跟进的事里完成了的、出错的，与它新问你的几条。从库里的事实生成，不调模型。
nonisolated struct CueAway: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        var id: UUID
        var title: String
    }

    var done: [Item]
    var failed: [Item]
    var asked: Int

    var isEmpty: Bool { done.isEmpty && failed.isEmpty && asked == 0 }

    static func read(since: Date, from store: isolated CueStore) throws -> CueAway {
        let changes = try store.cueChanges(since: since)
        func items(_ kind: CueChange.Kind, whole: Bool) -> [Item] {
            var seen = Set<UUID>()
            return changes.filter { $0.kind == kind && (!whole || $0.leaf == nil) }.compactMap { change in
                guard let task = change.task, seen.insert(task.id).inserted else { return nil }
                return Item(id: task.id, title: task.title)
            }
        }
        let failed = items(.failed, whole: false)
        return CueAway(
            done: items(.done, whole: true), failed: failed,
            asked: try store.cueMessagesWaitingForYou().filter { $0.createdAt > since }.count)
    }
}
