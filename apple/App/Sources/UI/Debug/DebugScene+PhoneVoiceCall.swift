#if os(iOS) && DEBUG
import AVFoundation
import UIKit

/// 手机发起的真实通话（媒体在这台，会话与鉴权在 Mac）：`-CuePadVoice <音频文件>` 在中转连上、Cue 能听后照通话钮拨出（`Workspace.startVoiceCall`），
/// Mac 投影到"在听"时把文件当你说的话送进上行（`DebugHooks.phoneVoiceSource`）；`-CuePadVoiceSeconds`（默认 60）后挂断。
/// Mac 那端起一个带 `-CuePadVoiceToken`、不带 `-CuePadVoice` 的实例，两端用同一朵模拟云（`-CuePadSharedCloud`，同一个中转房间）。
/// 对方的声音录到 `-CuePadVoiceRecord <wav>`，节点写进 `-CuePadVoiceLog <文件>`（`DebugVoiceLog`）：阶段、回应、下行响停、进出后台，
/// 结束前一行 `input-max` 是这一通上行的最大电平（`-CuePadVoice mic` 时看麦克风有没有真的进声音）。
/// 后台：`-CuePadVoicePlayInBackground YES` 在听后记 `waiting-background`、等 App 进后台（外面 `xcrun simctl launch <UDID> com.apple.Preferences` 把它压下去）1 秒再送文件，
/// 核对上下行、委派与挂断都在后台照常；下行这时走真的扬声器（静音、不录，`VoiceFixture.Downlink.speaker`），进了后台电平就停（`VoiceAudio`），没有 `output-loud`，回应看 Mac 的转写。中断：`-CuePadVoiceInterruptAfter <秒>` 在听后发系统收走声音时的那条通知，核对通话带"音频已中断"结束、Mac 收到挂断。
/// 信令断开：`-CuePadVoiceDropRelay <在听后秒>,<断多久秒>` 断掉这台的中转连接（记 `relay-drop`），`link` 一行是通话链路的变化（等 Mac 回来、换绑），
/// `projection` 一行是 Mac 投影的条数与阶段：断开期间通话照常，回来后投影补到最新；断得比宽限期（15 秒）久就带"网络断了"结束。
/// 音频会话与真机同一种（录音类），模拟器一接通就弹麦克风授权：`simctl privacy grant` 写进了授权库也照弹（iOS 27 模拟器实测），不点它不挡通话。
/// 负载很高时模拟器初始化扬声器会 RPC 超时、App 被系统中止（崩溃报告停在 `AURemoteIO::Initialize`），不是这里的问题，重跑。
extension DebugScene {
    /// 系统收走会话时通知里带的来源（`VoiceAudioSession` 只认它）：这个类型只由系统建、没有公开的构造，经运行时建一个、填上 system。
    private static func systemDeactivation() -> NSObject {
        let context = (NSClassFromString("AVAudioSessionDeactivationContext") as! NSObject.Type).init()
        context.setValue(AVAudioSession.DeactivationSource.system.rawValue, forKey: "source")
        return context
    }

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
        var inputPeak = 0.0
        let background = NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification)
        let foreground = NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification)
        var watching = [
            Task { for await response in Observations({ voice.response }) { note("response \(response)") } },
            Task { for await loud in Observations({ voice.outputActive }) { note(loud ? "output-loud" : "output-quiet") } },
            Task { for await samples in Observations({ voice.inputSamples }) { inputPeak = max(inputPeak, samples.max() ?? 0) } },
            Task { for await link in Observations({ voice.phone?.link }) { note("link \(link.map { "\($0)" } ?? "none")") } },
            Task { for await value in Observations({ voice.projection.map { "\($0.requests.count) \($0.phase)" } }) { note("projection \(value ?? "none")") } },
            Task { for await _ in background { note("app-background") } },
            Task { for await _ in foreground { note("app-foreground") } },
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
                if let drop = dropRelay(note: note) { watching.append(drop) }
                if args.voiceOpts.repeatOnReturn {
                    watching.append(Task {
                        for await availability in Observations({ voice.availability }) where availability == .unavailable { break }
                        for await availability in Observations({ voice.availability }) { if case .ready = availability { break } }
                        guard let reply = voice.projection?.replies.last?.message else { return note("repeat-skipped no reply") }
                        note("repeat \(reply)")
                        do { note("repeat-result \(try await workspace.repeatVoiceReply(reply, command: UUID()))") }
                        catch { note("repeat-error \(error)") }
                    })
                }
                if args.voiceOpts.interruptAfter > 0 {
                    watching.append(Task {
                        guard await Task.wait(for: .seconds(args.voiceOpts.interruptAfter)) else { return }
                        note("interrupt")
                        NotificationCenter.default.post(name: AVAudioSession.didBecomeInactiveNotification, object: AVAudioSession.sharedInstance(),
                                                        userInfo: [AVAudioSession.deactivationContextKey: systemDeactivation()])
                    })
                }
                if let fixture = phoneVoiceFixture {
                    let backgrounded = NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification)
                    watching.append(Task {
                        if args.voiceOpts.playInBackground {
                            note("waiting-background")
                            for await _ in backgrounded { break }
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
        note(String(format: "input-max %.3f", inputPeak))
        note("end \(voice.phase.map { "\($0)" } ?? "none")")
    }
}
#endif
