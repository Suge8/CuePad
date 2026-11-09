#if os(iOS) && DEBUG
import AVFoundation
import UIKit

/// 手机发起的真实通话（媒体在这台，会话与鉴权在 Mac）：`-CuePadVoice <音频文件>` 在中转连上、Cue 能听后照通话钮拨出（`Workspace.startVoiceCall`），
/// Mac 投影到"在听"时把文件当你说的话送进上行（`DebugHooks.phoneVoiceSource`）；`-CuePadVoiceSeconds`（默认 60）后挂断。
/// Mac 那端起一个带 `-CuePadVoiceToken`、不带 `-CuePadVoice` 的实例，两端用同一朵模拟云（`-CuePadSharedCloud`，同一个中转房间）。
/// 对方的声音录到 `-CuePadVoiceRecord <wav>`，节点写进 `-CuePadVoiceLog <文件>`（`DebugVoiceLog`）：阶段、回应、下行响停、进出后台。
/// 后台：`-CuePadVoicePlayInBackground YES` 在听后记 `waiting-background`、等 App 进后台（外面 `xcrun simctl launch <UDID> com.apple.Preferences` 把它压下去）1 秒再送文件，
/// 核对上下行、委派与挂断都在后台照常；下行这时走真的扬声器（静音、不录，`VoiceFixture.Downlink.speaker`），回应看 `output-loud` 与 Mac 的转写。中断：`-CuePadVoiceInterruptAfter <秒>` 在听后发系统收走声音时的那条通知，核对通话带"音频已中断"结束、Mac 收到挂断。
/// 音频会话与真机同一种（录音类），模拟器一接通就弹麦克风授权：`simctl privacy grant` 写进了授权库也照弹（iOS 27 模拟器实测），不点它不挡通话。
/// 负载很高时模拟器初始化扬声器会 RPC 超时、App 被系统中止（崩溃报告停在 `AURemoteIO::Initialize`），不是这里的问题，重跑。
extension DebugScene {
    static let phoneVoiceFixture: VoiceFixture? = args.voice.flatMap {
        $0 == "mic" ? nil : VoiceFixture(downlink: args.voiceOpts.playInBackground ? .speaker : args.voiceOpts.record != nil ? .record : .discard)
    }

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
        var listened = false
        for await phase in Observations({ voice.phase }) {
            note("phase \(phase.map { "\($0)" } ?? "none")")
            if !listened, phase == .listening {
                listened = true
                if args.voiceOpts.interruptAfter > 0 {
                    watching.append(Task {
                        guard await Task.wait(for: .seconds(args.voiceOpts.interruptAfter)) else { return }
                        note("interrupt")
                        NotificationCenter.default.post(name: AVAudioSession.didBecomeInactiveNotification, object: AVAudioSession.sharedInstance())
                    })
                }
                if let fixture = phoneVoiceFixture {
                    watching.append(Task {
                        if args.voiceOpts.playInBackground {
                            note("waiting-background")
                            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) { break }
                            guard await Task.wait(for: .seconds(1)) else { return }
                        }
                        note("play \(input)")
                        do { try fixture.play(URL(filePath: input)) } catch { abandon("声源文件没能送出", error) }
                    })
                }
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
