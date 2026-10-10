import CueStore
import Foundation

/// 任务看板（手机任务页、Mac 任务面板共用）：进行中、待办、最近完成，各自跨项目。进行中与待办按顶层任务的状态分组，
/// 子任务（没完成的，不论自己的状态）跟在它的顶层任务下（`tree`）；顺序同 `store.tasks(_:)`（项目顺序、未分类在后，同级手动顺序）。
/// 最近完成只列顶层任务（与 `counts.done` 同一批，也是"全部归档"动的那批；做完的子任务算在上级的进度里），不分项目、不分层，按完成时间从新到旧取前 `doneLimit` 条。
/// 每条带所在项目；交给 Pi 的带那个会话此刻的状态。
nonisolated struct TaskBoard: Sendable, Equatable {
    struct Row: Identifiable, Sendable, Equatable {
        var task: Card
        var project: Project?
        /// 交给 Pi 的任务关联的会话（同步记录）；没交给 Pi 或记录已没有时为 nil。
        var session: PiSessionState?
        /// 发给那个会话的最近一条投送请求（显示状态见 `PiDelivery`）。
        var delivery: DeliveryRequest?
        var id: UUID { task.id }

        /// 书架上排前后的档：0 等你确认或出错，1 正在干活，2 其余。
        var attention: Int {
            guard let session else { return 2 }
            return session.waitsForYou || session.state == .known(.error) ? 0 : session.isWorking ? 1 : 2
        }

        static func read(_ task: Card, projects: [UUID: Project], from store: isolated CueStore) throws -> Row {
            let item = try task.piSessionID.flatMap {
                try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: $0))).items.first
            }
            return Row(task: task, project: task.projectID.flatMap { projects[$0] }, session: item?.state, delivery: item?.delivery)
        }
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
    /// 任务的直接下级（子任务与挂着的灵感），完成圈与子任务进度由它推出。
    var children: [UUID: [ChildMark]]

    /// 两组的计数（顶层任务数，`CueStore.taskCounts` 一处定义）：任务页与面板的分组标题与"最近完成"、书架的"任务"一行、Mac 工具栏任务钮都读它。
    var counts: TaskCounts

    /// 看板要观察的表。
    static let tables: Set<Table> = [.cards, .projects, .piSessionStates, .deliveryRequests]

    static func read(from store: isolated CueStore) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        func row(_ task: Card) throws -> Row { try Row.read(task, projects: projects, from: store) }
        // 层级限制按库里全部任务（含已完成）算：与 Store 写入时的校验同一口径
        let all = try store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)
        let rows = Dictionary(uniqueKeysWithValues: try tree.ordered.map { ($0.id, try row($0)) })
        let roots = tree.roots.compactMap { rows[$0] }
        let listed = Set(all.map(\.id))
        let done = all.filter { $0.status == .done && !($0.parentID.map(listed.contains) ?? false) }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return TaskBoard(
            tree: tree, inProgress: roots.filter { $0.task.status == .inProgress }, todo: roots.filter { $0.task.status == .todo },
            done: try done.prefix(doneLimit).map(row), rows: rows, children: try store.childMarks(), counts: try counts(from: store))
    }

    /// 书架"正在推进"：列出的行，加上放不下的还有几项（纸底写"还有 N 项"）。
    struct Active: Sendable, Equatable {
        var rows: [Row]
        var more: Int
    }

    /// 正在推进的任务（书架顶上）：顶层的进行中任务（与 `counts.inProgress` 同一批，子任务跟着上级），先看交给的 Agent 在怎样——
    /// 等你确认、出错的在前，正在干活的其次，别的最后——同档最近开始的在前，再同的按原来的先后；取前 `limit` 条，其余数个数。
    static func active(limit: Int, from store: isolated CueStore) throws -> Active {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        let all = try store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)
        let rows = try tree.roots.compactMap(tree.task).filter { $0.status == .inProgress }.map { try Row.read($0, projects: projects, from: store) }
        let ordered = rows.enumerated().sorted { a, b in
            if a.element.attention != b.element.attention { return a.element.attention < b.element.attention }
            let (started, other) = (a.element.task.startedAt ?? .distantPast, b.element.task.startedAt ?? .distantPast)
            return started != other ? started > other : a.offset < b.offset
        }.map(\.element)
        return Active(rows: Array(ordered.prefix(limit)), more: max(0, ordered.count - limit))
    }

    /// 各项目的进行中任务，最近开始的在前（项目的"此刻"一行，`ProjectNow`）：一次查询，按项目归拢。
    static func leading(from store: isolated CueStore) throws -> [UUID: [ProjectNow.InProgress]] {
        var result: [UUID: [ProjectNow.InProgress]] = [:]
        for task in try started(from: store) {
            guard let project = task.projectID else { continue }
            result[project, default: []].append(ProjectNow.InProgress(id: task.id, title: task.title.textGlyphs))
        }
        return result
    }

    private static func started(from store: isolated CueStore) throws -> [Card] {
        try store.tasks(.inProgress).flatMap(\.tasks).sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
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
