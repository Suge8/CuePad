#if DEBUG
extension DebugSceneEntry {
    /// trash、archive：回收站与归档。
    static let bins = DebugSceneEntry("trash", "archive") { workspace, _ in
        #if os(macOS)
        workspace.show(DebugScene.scene == "trash" ? .trash : .archive)
        #else
        workspace.select(DebugScene.scene == "trash" ? .trash : .archive)
        #endif
    }
}
#endif
