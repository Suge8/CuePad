#if DEBUG
extension DebugSceneEntry {
    /// earlier："更早"那一页（配 `-CuePadDemo YES` 有演示的已结束会话）。
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
