#if DEBUG
extension DebugSceneEntry {
    /// task：打开一条任务的气泡（没有落点、在上方居中）。Mac 是本项目第一条没完成的顶层任务，iOS 是进行中的第一条；`-CuePadTask <标题开头>` 指定那一条（配 `-CuePadCanvasSteps YES` 有一条子任务都还没开工的"画布缩放锚点跟随指针"）。
    /// more（iOS）：进行中第一条的"⋯ 更多"气泡（任务行左滑那一下，没有落点），`-CuePadTurnCycle YES` 配 more、task、search 就绪后来回翻页、换范围。
    static let task = DebugSceneEntry("task", "more") { workspace, _ in
        try await DebugScene.openTaskScene(workspace)
    }
}

extension DebugScene {
    fileprivate static func openTaskScene(_ workspace: Workspace) async throws {
        await seedCanvasSteps(workspace.services.store)
        #if os(macOS)
        try await borrowDemoAgents(workspace.services)
        await openTask(workspace) { $0.parentID == nil && $0.projectID == workspace.currentProject }
        if args.launchFailed { try await failLead(workspace) }
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

    #if os(macOS)
    /// 走真的失败那一路（`Workspace.launch` 记下原因）：原因怎么写、写在哪与真的没开成一样。
    private static func failLead(_ workspace: Workspace) async throws {
        guard let task = workspace.openTask?.task,
              let leaf = try await workspace.services.store.children(of: task).first(where: { $0.isTask && $0.status != .done })
        else { return }
        await workspace.launch(workspace.sessionLaunching(.card(leaf.id))) { _, _ in
            throw SendError.noAgent(here: true, String(localized: "Pi 没装在这台 Mac 上", table: "Demo"))
        }?.value
    }
    #endif
}
#endif
