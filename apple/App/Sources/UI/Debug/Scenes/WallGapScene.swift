#if DEBUG && os(macOS)
import CueStore

extension DebugSceneEntry {
    /// wallgap（配 `-CuePadProject Flow`）：卡片墙删卡后的排布——新记两条，再删掉最早那条（它独占一列），看留下的几张怎么排。
    static let wallGap = DebugSceneEntry("wallgap") { workspace, _ in
        await DebugScene.running("卡片墙删卡") { try await DebugScene.wallGap(workspace) }
    }

    /// select：批量选择本页前三条灵感。
    static let select = DebugSceneEntry("select") { workspace, _ in
        await Task.wait(for: .seconds(1))
        for id in workspace.presses.selectable.prefix(3) { workspace.presses.toggle(id) }
    }
}

extension DebugScene {
    fileprivate static func wallGap(_ workspace: Workspace) async throws {
        await Task.wait(for: .seconds(1))
        let project = workspace.currentProject ?? Project.defaultID
        for body in [String(localized: "报销\nbs 84.36 刀 claude github", table: "Demo"), String(localized: "产品决策\nanti-slop 整理前端", table: "Demo")] {
            _ = try await workspace.createCard(body: body, in: project)
            await Task.wait(for: .milliseconds(300))
        }
        await Task.wait(for: .seconds(1))
        let cards = try await workspace.services.store.cards(in: project)
        if let oldest = cards.filter({ !$0.isTask }).min(by: { $0.modifiedAt < $1.modifiedAt }) { try await workspace.trash(oldest.id) }
    }
}
#endif
