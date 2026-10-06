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

    var isEmpty: Bool { inProgress.isEmpty && todo.isEmpty && done.isEmpty }

    static func read(from store: isolated CueStore) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        func row(_ task: CueTask) throws -> Row {
            let session = try task.piSessionID.flatMap {
                try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: $0))).items.first?.state
            }
            return Row(task: task, project: task.projectID.flatMap { projects[$0] }, session: session)
        }
        let open = try store.tasks(.inProgress, .todo).flatMap(\.tasks)
        let tree = TaskTree(open)
        let rows = Dictionary(uniqueKeysWithValues: try open.map { ($0.id, try row($0)) })
        let roots = tree.roots.compactMap { rows[$0] }
        let done = try store.tasks(.done).flatMap(\.tasks).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return TaskBoard(
            tree: tree, inProgress: roots.filter { $0.task.status == .inProgress }, todo: roots.filter { $0.task.status == .todo },
            done: try done.prefix(doneLimit).map(row), rows: rows, subtasks: try store.subtaskProgress())
    }
}
