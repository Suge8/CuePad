#if os(macOS)
import Foundation

/// 在 Mac 上起一通和 Cue 的通话；通话里的动作与手机同一份（`Workspace.performVoice`）。
/// 交出来的话走"对 Cue 说"同一个入口（`speak` 到 `.cue`），所以 Cue 没启用（听不到）时不起通话。
extension Workspace {
    /// 菜单的动作；无人值守与人工验收（`DebugScene.voiceCallIfAsked`）走同一个，只换声源。
    func toggleVoiceCall(source: VoicePeer.Source = .microphone) {
        if let voice, voice.isLive { return voice.hangUp() }
        startVoiceCall(source: source)
    }

    func startVoiceCall(source: VoicePeer.Source = .microphone) {
        showCue()
        guard voice?.isLive != true else { return }
        guard cue.canHear else { return say("Cue 还没启用，启用后才能通话", tone: .failure) }
        // 常驻通话栏呈现连接、回应和失败；浮动提示会遮住声纹与挂断入口。
        services.voice.startLocal(source: source)
    }
}
#endif
