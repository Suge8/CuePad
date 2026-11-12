#if DEBUG
extension DebugSceneEntry {
    static let earlier = DebugSceneEntry("earlier") { workspace, _ in
        #if os(iOS)
        if DebugScene.args.demo { await DebugScene.seedCue(workspace.services) }
        workspace.push(.earlier)
        #endif
    }
}
#endif
