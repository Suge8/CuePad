import CueStore
import Foundation

/// 任务看板（手机任务页、Mac 任务面板共用）：进行中、待办、最近完成，各自跨项目。进行中与待办按顶层任务的状态分组，
/// 步骤（没完成的，不论自己的状态）跟在它的顶层任务下（`tree`）；顺序同 `store.tasks(_:)`（项目顺序、未分类在后，同级手动顺序）。
/// 最近完成只列顶层任务（与 `counts.done` 同一批，也是"全部归档"动的那批；做完的步骤算在上级的进度里），不分项目、不分层，按完成时间从新到旧取前 `doneLimit` 条。
/// 每条带所在项目；交给的会话此刻怎样不在这里读，行取窗口那一份（`AgentLinks`，经 `Workspace.next(for:)`）。
nonisolated struct TaskBoard: Sendable, Equatable {
    struct Row: Identifiable, Sendable, Equatable {
        var task: Card
        var project: Project?
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
    /// 没完成的任务（含步骤）各自的项目。
    var rows: [UUID: Row]
    /// 任务的步骤完成了几个，完成圈与"步骤 n/m"由它推出。
    var subtasks: [UUID: TaskProgress]

    /// 两组的计数（顶层任务数，`CueStore.taskCounts` 一处定义）：任务页与面板的分组标题与"最近完成"、书架的"任务"一行、Mac 工具栏任务钮都读它。
    var counts: TaskCounts
    /// 三组从上到下的任务 id：列表增删、挪动的动画键，读库时算一次（放在 body 里每次重算都要分配）。
    var order: [UUID]

    static func read(from store: isolated CueStore) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        // 层级限制按库里全部任务（含已完成）算：与 Store 写入时的校验同一口径
        let all = try store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)
        let done = recentlyDone(all)
        func row(_ task: Card) -> Row { Row(task: task, project: task.projectID.flatMap { projects[$0] }) }
        let rows = Dictionary(uniqueKeysWithValues: tree.ordered.map { ($0.id, row($0)) })
        let roots = tree.roots.compactMap { rows[$0] }
        let inProgress = roots.filter { $0.task.status == .inProgress }, todo = roots.filter { $0.task.status == .todo }
        let finished = done.map(row)
        return TaskBoard(
            tree: tree, inProgress: inProgress, todo: todo, done: finished, rows: rows, subtasks: try store.subtaskProgress(),
            counts: try counts(from: store), order: (inProgress + todo + finished).map(\.id))
    }

    /// 最近完成的顶层任务：`all`（同一范围里库中的全部任务）里完成了、上级不在其中的（与 `counts.done` 同一批），按完成时间从新到旧取前 `doneLimit` 条。
    /// 看板与项目页任务纸的"已完成"同一规则。
    static func recentlyDone(_ all: [Card]) -> [Card] {
        let listed = Set(all.map(\.id))
        return Array(all.filter { $0.status == .done && !($0.parentID.map(listed.contains) ?? false) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(doneLimit))
    }

    /// 书架"正在推进"：列出的任务，加上放不下的还有几项（纸底写"还有 N 项"）。
    struct Active: Sendable, Equatable {
        var tasks: [Card]
        var more: Int
    }

    /// 正在推进的任务（书架顶上）：顶层的进行中任务（与 `counts.inProgress` 同一批，步骤跟着上级），最近开始的在前，
    /// 同刻按原来的先后；取前 `limit` 条，其余数个数。书架不看会话，不读会话。
    static func active(limit: Int, from store: isolated CueStore) throws -> Active {
        let started = try store.startedTasks(topLevelOnly: true)
        return Active(tasks: Array(started.prefix(limit)), more: max(0, started.count - limit))
    }

    /// 各项目的进行中任务，最近开始的在前（项目的"此刻"一行，`ProjectNow`）：一次查询，按项目归拢。
    static func leading(from store: isolated CueStore) throws -> [UUID: [ProjectNow.InProgress]] {
        var result: [UUID: [ProjectNow.InProgress]] = [:]
        for task in try store.startedTasks() {
            guard let project = task.projectID else { continue }
            result[project, default: []].append(ProjectNow.InProgress(id: task.id, title: task.title.textGlyphs))
        }
        return result
    }

    /// 全部项目的顶层任务计数（回收站里的项目不算）。
    static func counts(from store: isolated CueStore) throws -> TaskCounts {
        try store.taskCounts().values.reduce(.zero, +)
    }
}

extension TaskCounts {
    /// "2 进行中 · 3 待办"；都做完了是"全部完成"。
    var summary: Dotted {
        Dotted(inProgress > 0 ? "\(inProgress) 进行中" : nil, todo > 0 ? "\(todo) 待办" : nil).nonEmpty ?? "全部完成"
    }
}
