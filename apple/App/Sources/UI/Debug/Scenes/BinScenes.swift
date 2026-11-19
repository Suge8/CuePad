#if DEBUG
import CueStore
extension DebugSceneEntry {
    /// archive 先把头几个项目各一条做完的任务与最早的灵感归档：演示库里没有归档的，不然只拍得到空页。
    static let bins = DebugSceneEntry("trash", "archive") { workspace, _ in
        if DebugScene.scene == "archive" {
            await DebugScene.running("归档演示") { try await DebugScene.archiveSome(workspace.services.store) }
        }
        #if os(macOS)
        workspace.show(DebugScene.scene == "trash" ? .trash : .archive)
        #else
        workspace.select(DebugScene.scene == "trash" ? .trash : .archive)
        #endif
    }
}

extension DebugScene {
    fileprivate static func archiveSome(_ store: CueStore) async throws {
        // 演示库跨次运行留着：归档过就不再归，不然每拍一次少几条
        guard try await store.archived().isEmpty else { return }
        for project in try await store.projects().prefix(4) {
            let idea = try await store.cards(in: project.id).filter { !$0.isTask }.min { $0.modifiedAt < $1.modifiedAt }
            let task = try await store.tasks(in: project.id, .done).first
            for card in [idea, task].compactMap(\.self) { _ = try await store.archive(card.id) }
        }
    }
}
#endif