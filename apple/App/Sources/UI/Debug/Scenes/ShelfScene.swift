#if DEBUG
extension DebugSceneEntry {
    /// shelf：项目列表（书架；窄屏侧栏与宽屏主区的"项目"）。
    static let shelf = DebugSceneEntry("shelf") { workspace, _ in
        #if os(macOS)
        workspace.show(.shelf)
        #else
        workspace.select(.shelf)
        #endif
    }
}
#endif
