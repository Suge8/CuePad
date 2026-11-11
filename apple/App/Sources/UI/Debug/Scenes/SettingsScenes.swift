#if DEBUG
#if os(macOS)
import AppKit
import CueBridge
#endif

extension DebugSceneEntry {
    /// settings：设置。Mac 拍真的设置窗口（主窗口不带淡出地收起，`-CuePadSettingsPane general|agents` 翻到那一页）；配 `-CuePadDemo YES` 时 Cue 运行在演示的 Mac Studio 上。
    static let settings = DebugSceneEntry("settings") { workspace, _ in
        #if os(macOS)
        await DebugScene.seedDemo(workspace.services)
        SettingsPane.open(DebugScene.args.settingsPane.flatMap(SettingsPane.init(rawValue:)))
        DebugScene.mainWindow?.animationBehavior = .none
        DebugScene.mainWindow?.orderOut(nil)
        #else
        if DebugScene.args.demo { await DebugScene.seedCue(workspace.services) }
        workspace.select(.settings)
        #endif
    }

    #if os(macOS)
    /// agentsetup：首次打开的接入面板（接入 Agent 并启用 Cue；配 `-CuePadAgentHome <空目录>` 看一家都没装时的安装与登录，配 `-CuePadSync newmac` 看换新 Mac 时 Cue 那一行在等）。
    /// `-CuePadConnected YES`：几家先都接进隔离目录，看第二步（技能与规则收到一处）；面板打开后自己再检测一遍，等它检测完再拍。
    static let agentSetup = DebugSceneEntry("agentsetup") { workspace, _ in
        let connected = DebugScene.args.connected
        if connected {
            await DebugScene.connectAgents(workspace.services)
            await DebugScene.seedDemo(workspace.services)
            await workspace.recheckAgents()
        }
        workspace.showsSetup = true
        if connected { await Task.wait(for: .seconds(3)) }
    }

    /// connected：几家 Agent 接进隔离目录、打开进展页，看接入后的会话与新会话里选 Agent；`-CuePadFolder <路径>` 再建一个绑着这个文件夹的项目（隔离实例里真跑 Cue 派活用）。
    static let connected = DebugSceneEntry("connected") { workspace, _ in
        await DebugScene.connectAgents(workspace.services)
        await DebugScene.bindFolderIfAsked(workspace.services.store)
        workspace.show(.progress)
    }

    /// updatewait：托管的 Pi 在干活时检查更新——它撑得过重启，更新不等它、直接装（演示更新器打一个点）。托管的会话由 socket 目录里的假扩展连上来，连上后检查一次。
    static let updateWait = DebugSceneEntry("updatewait") { workspace, _ in
        await DebugScene.connectAgents(workspace.services)
        let pi = workspace.services.pi
        let busy = { pi.sessions.contains { $0.hosted && $0.state.hasPendingWork } }
        if !busy() { for await _ in pi.changes() where busy() { break } }
        workspace.services.updates.checkForUpdates()
        SettingsPane.open(.general)
        DebugScene.mainWindow?.animationBehavior = .none
        DebugScene.mainWindow?.orderOut(nil)
    }
    #endif
}
#endif
