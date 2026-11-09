#if os(iOS) && DEBUG
import Foundation

extension IOSInteractionBench {
    static let callSteps: Set<String> = ["接通·Cue 页", "在听·Cue 页", "挂断·Cue 页"]

    /// 和 Cue 通话（Cue 页上）：拨出时"对 Cue 说"原地变成通话条、接通到在听、挂断后变回输入框。投影与媒体是 `DebugPhoneVoiceReplay` 的替身，
    /// 挂断走正式的 `end`（替身关媒体 0.5 秒），所以挂断量 1.2 秒。只量其中几项时没点到的照样做（后一项要前一项摆好的通话），只是不量。
    static func call(_ workspace: Workspace, wants: (String) -> Bool, step: (String, Duration, @escaping () -> Void) async -> Void) async {
        let voice = workspace.services.voice
        voice.availability = .ready(endpoint: VoiceEndpoint(device: VoiceDeviceID("voice-bench-phone"), lease: UUID()))
        func go(_ name: String, _ window: Duration, _ action: @escaping () -> Void) async {
            if wants(name) { await step(name, window, action) } else { action(); await Task.wait(for: window + .milliseconds(1200)) }
        }
        for _ in 0..<2 {
            await go("接通·Cue 页", .milliseconds(800)) { DebugPhoneVoiceReplay.dial(voice) }
            await go("在听·Cue 页", .milliseconds(800)) { DebugPhoneVoiceReplay.answer(voice) }
            await go("挂断·Cue 页", .milliseconds(1200)) { Task { await voice.end() } }
        }
    }
}
#endif
