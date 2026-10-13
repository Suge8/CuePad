import CueStore
import Foundation

/// Cue 页一次读到的：最近的对话、对话里派出的每件活此刻的样子、在等你的那几条。
nonisolated struct CueThread: Equatable, Sendable {
    var messages: [CueMessage]
    var tasks: [UUID: CueLiveTask]
    var waiting: [CueMessage]

    /// 读最近这么多条对话（更早的不在 Cue 页里翻：要找旧事问 Cue）。
    static let limit = 200

    static func read(from store: isolated CueStore) throws -> CueThread {
        let messages = try store.cueMessages(limit: limit)
        var tasks: [UUID: CueLiveTask] = [:]
        for id in Set(messages.compactMap(\.taskID)) {
            if let live = try CueLiveTask.read(id, from: store) { tasks[id] = live }
        }
        return CueThread(messages: messages, tasks: tasks, waiting: try store.cueMessagesWaitingForYou())
    }

    /// 对话里的一格：你的话、Cue 的话（第一次提到一件活时下面带它的实时卡片），连着的几条动态收成一格；交接备忘不显示。
    /// 还在等你的不在对话里（只在输入框上方的"等你"里，一处），答了才回到它原来的位置，带着你选的那一项。
    enum Row: Identifiable, Equatable {
        case you(CueMessage)
        case cue(CueMessage, card: UUID?)
        case notes([CueMessage])

        var id: UUID {
            switch self {
            case .you(let message), .cue(let message, _): message.id
            case .notes(let group): group[0].id
            }
        }
    }

    var rows: [Row] {
        var shown = Set<UUID>()
        var rows: [Row] = []
        for message in messages {
            switch message.author.known {
            case .you: rows.append(.you(message))
            case .cue:
                if message.isWaiting { continue }
                let card = message.taskID.flatMap { tasks[$0] != nil && shown.insert($0).inserted ? $0 : nil }
                rows.append(.cue(message, card: card))
            case .note:
                if case .notes(let group) = rows.last { rows[rows.count - 1] = .notes(group + [message]) } else { rows.append(.notes([message])) }
            case .handoff, nil: break
            }
        }
        return rows
    }
}

/// 一件派出去的活此刻的样子（Cue 页里的实时卡片）：任务、步骤进度、在做的那一步与它的会话、最近一份预览。
nonisolated struct CueLiveTask: Equatable, Sendable {
    var task: Card
    var progress: TaskProgress?
    var leaf: Card
    var session: PiSessionState?
    /// 各步骤会话里发来看的文件，新的在前，至多 `previewLimit` 份（卡片放第一份，"等你"放全部：验收看的就是它们）。
    var previews: [PiPreview]
    var launching: Bool

    static let previewLimit = 4

    /// 卡片不在了（删掉、改回灵感）为 nil：那句话照常显示，不带卡片。
    static func read(_ id: UUID, from store: isolated CueStore) throws -> CueLiveTask? {
        guard let card = try store.card(id), card.isTask, card.deletedAt == nil else { return nil }
        let detail = try store.cueTaskDetail(id, rounds: 0)
        let current = detail.leaves.first { $0.leaf.status != .done } ?? detail.leaves.last
        guard let current else { return nil }
        return CueLiveTask(
            task: detail.task, progress: detail.progress, leaf: current.leaf, session: current.session,
            previews: Array(detail.leaves.flatMap(\.previews).sorted { $0.createdAt > $1.createdAt }.prefix(previewLimit)),
            launching: try !store.launchingLeaves([current.leaf.id]).isEmpty)
    }

    var done: Bool { task.status == .done }
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
