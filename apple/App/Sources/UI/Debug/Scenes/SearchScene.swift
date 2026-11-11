#if DEBUG
extension DebugSceneEntry {
    static let search = DebugSceneEntry("search") { workspace, _ in
        #if os(macOS)
        workspace.searching = true
        #else
        workspace.openSearch()
        #endif
    }
}
#endif
