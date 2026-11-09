#if DEBUG
extension DebugSceneEntry {
    static let shelf = DebugSceneEntry("shelf") { workspace, _ in
        #if os(macOS)
        workspace.show(.shelf)
        #else
        workspace.select(.shelf)
        #endif
    }
}
#endif
