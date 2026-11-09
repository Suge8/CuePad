#if os(iOS)
extension DebugHooks {
    static func preparePhoneVoice(_ workspace: Workspace) async {
        #if DEBUG
        await DebugPhoneVoice.prepare(workspace)
        #endif
    }

    /// 手机通话的声源：调试时 `-CuePadVoice <音频文件>` 换成文件（`DebugScene.phoneVoiceCallIfAsked`）。
    static var phoneVoiceSource: VoicePeer.Source {
        #if DEBUG
        if let fixture = DebugScene.phoneVoiceFixture { return .fixture(fixture) }
        #endif
        return .microphone
    }
}
#endif
