#if DEBUG
extension DebugSceneEntry {
    /// task：打开一条任务的气泡（没有落点、在上方居中）。Mac 是本项目第一条没完成的顶层任务，iOS 是进行中的第一条；`-CuePadTask <标题开头>` 指定那一条。
    /// more（iOS）：进行中第一条的"⋯ 更多"气泡（任务行左滑那一下，没有落点），`-CuePadTurnCycle YES` 配 more、task、search 就绪后来回翻页、换范围。
    static let task = DebugSceneEntry("task", "more") { workspace, _ in
        try await DebugScene.openTaskScene(workspace)
    }
}

extension DebugScene {
    fileprivate static func openTaskScene(_ workspace: Workspace) async throws {
        #if os(macOS)
        try await borrowDemoAgents(workspace.services)
        await openTask(workspace) { $0.parentID == nil && $0.projectID == workspace.currentProject }
        #else
        if scene == "more" {
            if let task = try await workspace.services.store.tasks(.inProgress, .todo).flatMap(\.tasks).first {
                workspace.moreCard = CardMoreRequest(card: task, opens: false, source: .unanchored)
            }
        } else {
            await openTask(workspace) { $0.status == .inProgress }
        }
        #endif
    }
}
#endif
