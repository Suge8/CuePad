import CueStore
import Foundation

/// 任务的三态看板（手机任务页、Mac 任务面板共用）：进行中、待办、最近完成，各自跨项目（顺序同 `store.tasks(_:)`：
/// 项目顺序、未归档在后；组内手动顺序，完成的最近完成在前）。每条带所在项目；交给 Pi 的带那个会话此刻的状态。
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
        func rows(_ status: TaskStatus, limit: Int = .max) throws -> [Row] {
            try store.tasks(status).flatMap(\.tasks).prefix(limit).map { task in
                let session = try task.piSessionID.flatMap {
                    try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: $0))).items.first?.state
                }
                return Row(task: task, project: task.projectID.flatMap { projects[$0] }, session: session)
            }
        }
        return TaskBoard(inProgress: try rows(.inProgress), todo: try rows(.todo), done: try rows(.done, limit: doneLimit))
    }
}
