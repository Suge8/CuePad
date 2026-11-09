#if DEBUG
import CueStore
import Foundation

extension DebugSceneEntry {
    static let editor = DebugSceneEntry("editor") { workspace, project in
        try await DebugScene.openEditor(workspace, project: project)
    }
}

extension DebugScene {
    fileprivate static func openEditor(_ workspace: Workspace, project: UUID?) async throws {
        let store = workspace.services.store
        #if os(macOS)
        await running("打开编辑页") {
            if let id = try await card(in: workspace.currentProject ?? Project.defaultID, store: store),
               let card = try await store.card(id) { workspace.open(card) }
        }
        #else
        try await openCard(workspace, project: project)
        #endif
    }
}
#endif
