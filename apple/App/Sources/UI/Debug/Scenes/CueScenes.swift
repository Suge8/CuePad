#if DEBUG
extension DebugSceneEntry {
    /// cuememory 再打开"Cue 记得什么"，cueschedules 再打开定时，cuerun（仅 Mac）再打开"运行情况"（Cue 在这台值班时才有）。`-CuePadCuePresence away`：一夜里 Cue 陆续说了几句，回到 Cue 页从新消息读起。
    static let cue = DebugSceneEntry("cue", "cuememory", "cueschedules", "cuerun") { workspace, _ in
        let scene = DebugScene.scene
        #if os(macOS)
        await DebugScene.seedDemo(workspace.services)
        if DebugScene.args.noAsks { await DebugScene.settleAsks(workspace.services.store) }
        workspace.show(.cue)
        if scene == "cuememory" { workspace.cue.showsMemory = true }
        if scene == "cueschedules" { workspace.cue.showsSchedules = true }
        if scene == "cuerun" { workspace.cue.showsRun = true }
        #else
        // 一夜里来的话要在不看 Cue 页时写（看着时写当场就读掉了）：先离开、写完再回来，才是"回来时有新消息"的样子
        if DebugScene.args.cueOpts.presence == "away" {
            workspace.show(.progress)
            await NextFrame.wait()
        }
        if DebugScene.args.demo { await DebugScene.seedCue(workspace.services) }
        if let draft = DebugScene.args.cueOpts.draft { workspace.cue.draft.text = draft }
        workspace.show(.cue)
        if workspace.layout == .wide { workspace.sidebarOpen = true }
        if scene == "cuememory" { workspace.cue.showsMemory = true } else { workspace.cue.showsSchedules = scene == "cueschedules" }
        if DebugScene.args.layoutOpts.panelCycle { Task { await DebugScene.cyclePanel() } }
        #endif
    }

    static let cueRows = DebugSceneEntry("cuerows") { workspace, _ in
        #if os(macOS)
        await DebugScene.connectAgents(workspace.services)
        await DebugScene.seedCueRows(workspace.services)
        workspace.show(.progress)
        #else
        await DebugScene.seedCueRows(workspace.services)
        workspace.openSearch()
        #endif
    }

    #if os(iOS)
    static let cuePanel = DebugSceneEntry("cuepanel") { workspace, project in
        if DebugScene.args.demo { await DebugScene.seedCue(workspace.services) }
        workspace.select(project.map(Route.project) ?? .shelf)
        workspace.show(.cue)
    }
    #endif
}
#endif
