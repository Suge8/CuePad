import CueStore
import SwiftUI

/// 一条任务的下级：任务页一次读出，各块只画。任务交给的会话在窗口那一份里（`AgentLinks`，环境 `cardAgents`）。
nonisolated struct TaskDetail: Sendable, Equatable {
    /// 步骤与挂在下面的灵感（资料），同级手动顺序。
    var children: [Card]

    static func read(_ id: UUID, from store: isolated CueStore) throws -> TaskDetail {
        TaskDetail(children: try store.children(of: id))
    }

    var subtasks: [Card] { children.filter(\.isTask) }
    var references: [Card] { children.filter { !$0.isTask } }

    /// 步骤完成了几个；没有步骤为 nil。完成圈与"步骤 n/m"按它画。
    var progress: TaskProgress? {
        let subtasks = subtasks
        return subtasks.isEmpty ? nil : TaskProgress(done: subtasks.filter { $0.status == .done }.count, total: subtasks.count)
    }
}
