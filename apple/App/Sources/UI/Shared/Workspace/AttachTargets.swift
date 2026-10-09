import CueStore
import Foundation

/// 灵感能挂到哪些任务（"挂到任务"的选择面板）：没做完的任务（含子任务，先序），按项目分组——灵感所在项目的在前，
/// 其余按项目的顺序（`CueStore.projects()`），没归项目的最后。
nonisolated enum AttachTargets {
    static func read(for idea: Card, from store: isolated CueStore) throws -> [TaskGroup] {
        let byProject = Dictionary(uniqueKeysWithValues: try store.tasks(.inProgress, .todo).map { ($0.projectID, $0) })
        var owners: [UUID?] = [idea.projectID]
        for id in try store.projects().map(\.id) + [nil] where !owners.contains(id) { owners.append(id) }
        return owners.compactMap { byProject[$0] }.filter { !$0.tasks.isEmpty }
    }
}

extension Workspace {
    /// 挂到一个新建的任务：任务建在灵感所在的项目，灵感成为它的第一条提示词（与挂到已有任务同一条通路，提示可撤销）。
    func attachToNewTask(_ idea: UUID, title: String) async throws {
        guard let card = try await services.store.card(idea) else { throw CueStoreError.notFound }
        let task = try await createTask(title, in: card.projectID)
        try await attach(idea, to: task.id)
    }
}
