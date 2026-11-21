#if os(iOS) && DEBUG
import Foundation

extension IOSInteractionBench {
    static let callSteps: Set<String> = ["接通·Cue 页", "在听·Cue 页", "挂断·Cue 页"]

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
