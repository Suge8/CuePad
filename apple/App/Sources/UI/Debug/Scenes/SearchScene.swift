#if DEBUG
extension DebugSceneEntry {
    /// search：搜索页，出现即聚焦并填入 `-CuePadSearch`；`-CuePadSearchScope sessions` 打开在会话那一栏。
    static let search = DebugSceneEntry("search") { workspace, _ in
        #if os(macOS)
        workspace.searching = true
        #else
        workspace.openSearch()
        #endif
    }
}
#endif
