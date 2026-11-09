#if DEBUG
import CueStore
import SwiftUI

extension DebugSceneEntry {
    /// newsession：新会话表单。Mac 把它放进主窗口里拍（平时从 + 弹出；配 `-CuePadDemo YES` 读演示 Mac 的 Agent）。
    /// iOS 是进展的看板上浮起新会话输入框，`-CuePadProject` 先选中那个项目，`-CuePadLaunch YES` 已经替你在圆桌发出（看送达中）。
    /// folderpicker（iOS）：给 `-CuePadProject`（默认闲鱼，演示里没绑文件夹）选文件夹的候选页。
    #if os(macOS)
    static let newSession = DebugSceneEntry("newsession", stage: { workspace in
        AnyView(DebugNewSessionForm().environment(workspace).frame(maxWidth: .infinity, maxHeight: .infinity))
    })
    #else
    static let newSession = DebugSceneEntry("newsession", "folderpicker", prepare: DebugScene.openNewSession)
    #endif
}

#if os(iOS)
extension DebugScene {
    fileprivate static func openNewSession(_ workspace: Workspace, _ project: UUID?) async throws {
        if scene == "folderpicker" {
            let name = args.project ?? String(localized: "闲鱼", table: "Demo")
            workspace.folderPicker = try await workspace.services.store.projects().first { $0.name == name }
            return
        }
        workspace.show(.progress)
        var sheet = SessionStart(project: project)
        if args.launch,
           let table = try await workspace.services.store.projects().first(where: { $0.name == String(localized: "圆桌", table: "Demo") })?.id {
            sheet.launched = try await workspace.services.launchSession(
                in: table, prompt: String(localized: "看看 scheduler 的重连问题", table: "Demo"), title: String(localized: "圆桌", table: "Demo"), on: "demo-mac", card: nil, agent: .pi)
        }
        workspace.newSession = sheet
    }
}
#endif
#endif
