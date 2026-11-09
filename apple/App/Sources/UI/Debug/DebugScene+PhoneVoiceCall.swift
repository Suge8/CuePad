#if os(iOS) && DEBUG
import UIKit

/// 手机发起的真实通话（媒体在这台，会话与鉴权在 Mac）：`-CuePadVoice <音频文件>` 在中转连上、Cue 能听后照通话钮拨出（`Workspace.startVoiceCall`），
/// Mac 投影到"在听"时把文件当你说的话送进上行（`DebugHooks.phoneVoiceSource`）；`-CuePadVoiceSeconds`（默认 60）后挂断。
/// Mac 那端起一个带 `-CuePadVoiceToken`、不带 `-CuePadVoice` 的实例，两端用同一朵模拟云（`-CuePadSharedCloud`，同一个中转房间）。
/// 对方的声音录到 `-CuePadVoiceRecord <wav>`，节点写进 `-CuePadVoiceLog <文件>`（`DebugVoiceLog`）：阶段、回应、下行响停、进出后台。
extension DebugScene {
    static let phoneVoiceFixture: VoiceFixture? = args.voice.flatMap { $0 == "mic" ? nil : VoiceFixture(recording: args.voiceOpts.record != nil) }

    static func phoneVoiceCallIfAsked(_ workspace: Workspace) async {
        guard let input = args.voice else { return }
        await running("手机通话") { try await phoneVoiceCall(workspace, input: input) }
    }

    private static func phoneVoiceCall(_ workspace: Workspace, input: String) async throws {
        let voice = workspace.services.voice
        let log = DebugVoiceLog()
        let note = log.note
        for await ready in Observations({ workspace.cue.canHear && voice.startUnavailableReason == nil }) where ready { break }
        var watching = [
            Task { for await response in Observations({ voice.response }) { note("response \(response)") } },
            Task { for await loud in Observations({ voice.outputActive }) { note(loud ? "output-loud" : "output-quiet") } },
            Task { for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) { note("app-background") } },
            Task { for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) { note("app-foreground") } },
        ]
        defer { watching.forEach { $0.cancel() } }
        phoneVoiceFixture?.finished = { note("input-ended \($0)") }
        note("dial")
        try await workspace.startVoiceCall()
        watching.append(Task {
            await Task.wait(for: .seconds(args.voiceOpts.seconds ?? 60))
            await workspace.hangUpVoiceCall()
        })
        var played = false
        for await phase in Observations({ voice.phase }) {
            note("phase \(phase.map { "\($0)" } ?? "none")")
            if !played, phase == .listening, let fixture = phoneVoiceFixture {
                played = true
                note("play \(input)")
                try fixture.play(URL(filePath: input))
            }
            if case .ended = phase { break }
            if case .failed = phase { break }
        }
        if let fixture = phoneVoiceFixture, let record = args.voiceOpts.record {
            try fixture.write(to: URL(filePath: record))
            note("recorded \(record)")
        }
        note("end \(voice.phase.map { "\($0)" } ?? "none")")
    }
}
#endif
