#if os(iOS)
extension DebugHooks {
    static func preparePhoneVoice(_ workspace: Workspace) async {
        #if DEBUG
        await DebugPhoneVoice.prepare(workspace)
        #endif
    }
}
#endif
