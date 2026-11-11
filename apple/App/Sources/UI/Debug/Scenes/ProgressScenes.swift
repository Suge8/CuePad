#if DEBUG
extension DebugSceneEntry {
    /// progress：进展页的看板。配 `-CuePadDemo YES` 写入演示会话与 Cue 的等你，推进中的带会话状态；`-CuePadProject` 先把范围设成它（iOS）。
    static let progress = DebugSceneEntry("progress") { workspace, project in
        let services = workspace.services
        #if os(macOS)
        await DebugScene.seedDemo(services)
        if DebugScene.args.demo { await DebugScene.seedBusyBoard(services.store) }
        #else
        if DebugScene.args.demo {
            await DebugScene.seedCue(services)
            await DebugScene.seedBusyBoard(services.store)
        }
        workspace.projectScope = project
        #endif
        await DebugScene.seedCanvasSteps(services.store)
        workspace.show(.progress)
    }

    /// sessions：会话在会话条上的进展（Mac，给了 `-CuePadProject` 先把项目范围设成它）；iOS 是搜索页的会话一栏（在线的与历史的会话行）。
    static let sessions = DebugSceneEntry("sessions") { workspace, project in
        #if os(macOS)
        await DebugScene.seedDemo(workspace.services)
        workspace.projectScope = project
        workspace.show(.progress)
        #else
        if DebugScene.args.demo { await DebugScene.seedCue(workspace.services) }
        workspace.openSearch()
        #endif
    }
}
#endif
