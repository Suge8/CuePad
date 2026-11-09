#if DEBUG
extension DebugSceneEntry {
    /// library：技能与规则（`-CuePadLibraryTab skills` 打开在技能那一段），再推入文件页：instruction 是全局规则（给了 `-CuePadProject` 是那个项目的，
    /// 演示的全局规则顶上有合并那一条，`-CuePadMergePreview YES` 已点过一下"合并进来"），skill 是 write-swift，duplicate 是同名的 release。配 `-CuePadDemo YES` 有演示的文件。
    static let library = DebugSceneEntry("library", "instruction", "skill", "duplicate") { workspace, project in
        guard let scene = DebugScene.scene else { return }
        #if os(macOS)
        if project == nil || scene != "instruction" { workspace.show(.library) }
        #else
        if DebugScene.args.demo { await DebugScene.seedCue(workspace.services) }
        workspace.select(.library)
        #endif
        workspace.libraryPane = DebugHooks.preset.libraryPane
        if let file = DemoAgentLibrary.file(scene: scene, project: project) { workspace.openLibrary(file) }
    }
}
#endif
