import CueStore
import Foundation

/// 任务的三态看板（手机任务页、Mac 任务面板共用）：进行中、待办、最近完成，各自跨项目。进行中与待办的顺序同 `store.tasks(_:)`
/// （项目顺序、未归档在后，组内手动顺序）；最近完成不分项目，按完成时间从新到旧取前 `doneLimit` 条。每条带所在项目；交给 Pi 的带那个会话此刻的状态。
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

    var inProgress: [Row]
    var todo: [Row]
    var done: [Row]

    var isEmpty: Bool { inProgress.isEmpty && todo.isEmpty && done.isEmpty }

    static func read(from store: isolated CueStore) throws -> TaskBoard {
        let projects = Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) })
        func rows(_ tasks: some Sequence<CueTask>) throws -> [Row] {
            try tasks.map { task in
                let session = try task.piSessionID.flatMap {
                    try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: $0))).items.first?.state
                }
                return Row(task: task, project: task.projectID.flatMap { projects[$0] }, session: session)
            }
        }
        let done = try store.tasks(.done).flatMap(\.tasks).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return TaskBoard(
            inProgress: try rows(store.tasks(.inProgress).flatMap(\.tasks)), todo: try rows(store.tasks(.todo).flatMap(\.tasks)),
            done: try rows(done.prefix(doneLimit)))
    }
}
