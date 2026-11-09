#if DEBUG
import CueStore
import Foundation

extension DebugSceneEntry {
    /// project、older、projectform、sidebar、collapsed：项目页与外框。
    /// older 是项目页滚到"更早"（`scrollIfNeeded`）；projectform 是项目表单（给了 `-CuePadProject` 是编辑该项目，否则新建；
    /// Mac 的表单经浮层弹出，在 `projectFormIfAsked`）；sidebar 是开着侧栏（给了 `-CuePadProject` 先打开那个项目）；collapsed（Mac）收起侧栏。
    static let project = DebugSceneEntry("project", "older", "projectform", "sidebar", "collapsed", prepare: DebugScene.openProject)
}

extension DebugScene {
    fileprivate static func openProject(_ workspace: Workspace, _ project: UUID?) async throws {
        #if os(iOS)
        switch scene {
        case "projectform":
            let existing = if let project { try await workspace.services.store.project(project) } else { Project?.none }
            workspace.projectForm = .init(project: existing)
        case "sidebar":
            if let project { workspace.select(.project(project)) }
            workspace.sidebarOpen = true
        default:
            if let project { workspace.select(.project(project)) }
        }
        #else
        if scene == "collapsed" { workspace.sidebarOpen = false }
        #endif
    }
}
#endif
