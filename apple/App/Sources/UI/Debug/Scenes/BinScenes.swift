#if DEBUG
extension DebugSceneEntry {
    static let bins = DebugSceneEntry("trash", "archive") { workspace, _ in
        #if os(macOS)
        workspace.show(DebugScene.scene == "trash" ? .trash : .archive)
        #else
        workspace.select(DebugScene.scene == "trash" ? .trash : .archive)
        #endif
    }
}
#endif
