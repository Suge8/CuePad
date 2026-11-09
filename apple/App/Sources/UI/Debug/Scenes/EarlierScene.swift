#if DEBUG
extension DebugSceneEntry {
    static let earlier = DebugSceneEntry("earlier") { workspace, _ in
        #if os(macOS)
        await DebugScene.seedDemo(workspace.services)
        workspace.show(.earlier)
        #else
        if DebugScene.args.demo { await DebugScene.seedCue(workspace.services) }
        workspace.push(.earlier)
        #endif
    }
}
#endif
