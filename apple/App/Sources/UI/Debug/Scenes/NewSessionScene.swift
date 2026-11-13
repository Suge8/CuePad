#if DEBUG
import CueStore
import SwiftUI

extension DebugSceneEntry {
    /// newsession：新会话的输入框（配 `-CuePadDemo YES` 时 Mac 把演示 Mac 的 Agent 抄给本机：隔离实例里这台一家都不能用，看不到选 Agent 与模型的那一排）。
    /// iOS 是进展的看板上浮起，`-CuePadProject` 先选中那个项目，`-CuePadLaunch YES` 已经替你在圆桌发出（看送达中）。
    /// folderpicker（iOS）：给 `-CuePadProject`（默认闲鱼，演示里没绑文件夹）选文件夹的候选页。
    #if os(macOS)
    static let newSession = DebugSceneEntry("newsession") { workspace, project in
        try await DebugScene.borrowDemoAgents(workspace.services)
        workspace.show(.progress)
        workspace.openNewSession(in: project)
    }
    #else
    static let newSession = DebugSceneEntry("newsession", "folderpicker", prepare: DebugScene.openNewSession)
    #endif
}

#if os(macOS)
extension DebugScene {
    static func borrowDemoAgents(_ services: AppServices) async throws {
        guard args.demo else { return }
        let demo = try await services.store.macAgents(on: "demo-mac")
        _ = try await services.store.recordMacAgents(host: services.hostID, name: demo.name, demo.agents)
    }
}
#endif

#if os(iOS)
extension DebugScene {
    fileprivate static func openNewSession(_ workspace: Workspace, _ project: UUID?) async throws {
        if scene == "folderpicker" {
            let name = args.project ?? String(localized: "闲鱼", table: "Demo")
            workspace.folderPicker = try await workspace.services.store.projects().first { $0.name == name }
            return
        }
        workspace.show(.progress)
        let sheet = SessionStart(project: project)
        if args.launch,
           let table = try await workspace.services.store.projects().first(where: { $0.name == String(localized: "圆桌", table: "Demo") })?.id {
            let launched = try await workspace.services.launchSession(
                in: table, prompt: String(localized: "看看 scheduler 的重连问题", table: "Demo"), title: String(localized: "圆桌", table: "Demo"), on: "demo-mac", card: nil, agent: .pi)
            workspace.resume(sheet.launchKey, with: launched, opened: Workspace.entering(sheet))
        }
        workspace.newSession = sheet
    }
}
#endif
#endif
