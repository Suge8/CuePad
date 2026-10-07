import CueStore
import Foundation

/// 任务看板（手机任务页、Mac 任务面板共用）：进行中、待办、最近完成，各自跨项目。进行中与待办按顶层任务的状态分组，
/// 子任务（没完成的，不论自己的状态）跟在它的顶层任务下（`tree`）；顺序同 `store.tasks(_:)`（项目顺序、未归档在后，同级手动顺序）。
/// 最近完成不分项目、不分层，按完成时间从新到旧取前 `doneLimit` 条。每条带所在项目；交给 Pi 的带那个会话此刻的状态。
nonisolated struct TaskBoard: Sendable, Equatable {
    struct Row: Identifiable, Sendable, Equatable {
        var task: CueTask
        var project: Project?
        /// 交给 Pi 的任务关联的会话（同步记录）；没交给 Pi 或记录已没有时为 nil。
        var session: PiSessionState?
        /// 发给那个会话的最近一条投送请求（显示状态见 `PiDelivery`）。
        var delivery: DeliveryRequest?
        var id: UUID { task.id }
    }

    /// 最近完成列多少条。
    static let doneLimit = 30

    /// 没完成的任务的层级。
    var tree: TaskTree
    /// 进行中、待办两组的顶层任务。
    var inProgress: [Row]
    var todo: [Row]
    var done: [Row]
    /// 没完成的任务（含子任务）各自的项目与会话。
    var rows: [UUID: Row]
    /// 上级任务的直接子任务完成数与总数。
    var subtasks: [UUID: TaskProgress]

    /// 进行中、待办两组各有几条顶层任务：子任务不另计（进度写在上级那一行）。任务页与面板的分组标题、书架的"任务"一行、
    /// Mac 工具栏任务钮上的数都是它。
    struct Counts: Sendable, Equatable {
        var inProgress: Int
        var todo: Int

        /// "2 进行中 · 3 待办"；都做完了是"全部完成"。
        var summary: String {
            let parts = [inProgress > 0 ? "\(inProgress) 进行中" : nil, todo > 0 ? "\(todo) 待办" : nil].compactMap { $0 }
            return parts.isEmpty ? "全部完成" : parts.joined(separator: " · ")
        }
    }

    var counts: Counts { Counts(inProgress: inProgress.count, todo: todo.count) }

    var isEmpty: Bool { inProgress.isEmpty && todo.isEmpty && done.isEmpty }

    /// 看板要观察的表。
    static let tables: Set<StoreTable> = [.tasks, .projects, .piSessionStates, .deliveryRequests]

    static func read(from store: isolated CueStore) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        func row(_ task: CueTask) throws -> Row {
            let item = try task.piSessionID.flatMap {
                try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: $0))).items.first
            }
            return Row(task: task, project: task.projectID.flatMap { projects[$0] }, session: item?.state, delivery: item?.delivery)
        }
        let tree = try openTree(from: store)
        let rows = Dictionary(uniqueKeysWithValues: try tree.ordered.map { ($0.id, try row($0)) })
        let roots = tree.roots.compactMap { rows[$0] }
        let done = try store.tasks(.done).flatMap(\.tasks).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return TaskBoard(
            tree: tree, inProgress: roots.filter { $0.task.status == .inProgress }, todo: roots.filter { $0.task.status == .todo },
            done: try done.prefix(doneLimit).map(row), rows: rows, subtasks: try store.subtaskProgress())
    }

    /// 只要计数时（书架、Mac 工具栏）：与 `read` 同一棵树、同一分组，不读会话与已完成列表。
    static func counts(from store: isolated CueStore) throws -> Counts {
        let tree = try openTree(from: store)
        let roots = tree.roots.compactMap(tree.task)
        return Counts(inProgress: roots.filter { $0.status == .inProgress }.count, todo: roots.filter { $0.status == .todo }.count)
    }

    /// 没完成的任务的层级；层级限制按库里全部任务（含已完成）算。
    private static func openTree(from store: isolated CueStore) throws -> TaskTree {
        let all = try store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        return TaskTree(all.filter { $0.status != .done }, all: all)
    }
}
