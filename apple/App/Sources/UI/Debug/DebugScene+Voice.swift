#if os(macOS) && DEBUG
import AppKit
import CueStore
import Foundation

/// 和 Cue 通话的验收（`xc.sh run mac` 起的实例没有菜单栏，菜单那一项点不到，这里调它的同一个动作 `Workspace.toggleVoiceCall`）：
/// - 给了 `-CuePadVoiceToken <文件>`（令牌由 `scripts/voice-token.py` 经本机 Codex app-server 获取，`DebugHooks.voiceToken`）就让 Cue 在这台启用。
///   配了 `-CuePadCueBrain apple/scripts/cue-brain-stub.py` 时运行时是 Pi、大脑是替身（回 `CUE_STUB_REPLY` 那句）；没配时是真的 Claude Code，
///   `-CuePadVoiceRuntime <pi|codex|claude>`、`-CuePadVoiceModel <模型>` 可指定其他已在隔离目录登录的运行时。
///   登录照 docs/verify.md「让 Cue 真跑」在起实例前交给它（`CLAUDE_CODE_OAUTH_TOKEN`）。
/// - `-CuePadVoice mic`：Cue 能听了就开始通话，声音走麦克风与扬声器（人工验收）。
///   `-CuePadVoice <音频文件>`：接通后把这个文件当你说的话送进上行（`VoiceFixture`，不碰麦克风）；
///   `-CuePadVoice <目录>`：按节点送 first.wav（接通后）、interrupt.wav（Cue 的结果送出、模型开口时）、stop.wav（这一轮落库且说完后），再说完就挂断。
///   对方的声音录到 `-CuePadVoiceRecord <wav>`（不外放；无人值守）。
/// - 没给 `-CuePadVoice` 时，手机发起、这台持有的通话照样记节点（手机那端见 `DebugScene+PhoneVoiceCall`）。
/// - `-CuePadVoiceReadFixture <原文>` 把原文作为隔离库的主动消息请 GPT Live 朗读，录成后续验收的声源；不使用系统 TTS。
/// - 到 `-CuePadVoiceSeconds`（默认 60）挂断；配 `-CuePadVoiceHangUpAfterReply YES` 时，结果送出后观察到实际输出、模型回合结束且下行安静才挂断。
///   `-CuePadVoiceKeepOpen YES` 在首轮挂断后保留窗口，供真实按钮重连与结果阅读验收；不延长通话时限。
///   `-CuePadVoiceReplay YES` 在 Cue 结果送出后重放原 delegation 与用户 turn.done，核对请求没有重复落库。
/// - 节点写进 `-CuePadVoiceLog <文件>`（`DebugVoiceLog`）。`input-ended` 是文件送完，`output-loud/quiet` 是下行实际的声音；
///   `cue-forward` 是落库结果与交接归属，`cue-sent` 是发送完成，`context-accepted` 是服务端追加回执，`assistant-said` 只是模型转写。
///   最后一行是终态与音频用量；原始控制事件写到 `-CuePadVoiceWireLog <文件>`，连同服务端在控制连接上回传的音频块
///   （`session.input_audio.append`、`session.output_audio.delta`）：与本机的 `input-loud`、`output-loud` 对齐即上下行各自的媒体时延。
extension DebugScene {
    static func voiceCallIfAsked(_ workspace: Workspace) async {
        guard args.voiceOpts.token != nil else { return }
        await running("语音通话") { try await voiceCall(workspace) }
    }

    private static func voiceCall(_ workspace: Workspace) async throws {
        let host = workspace.services.hostID
        let runtime = args.voiceOpts.runtime.flatMap(AgentKind.init(rawValue:))
            ?? (DebugHooks.cueBrain == nil ? .claudeCode : .pi)
        let model = args.voiceOpts.model
        try await workspace.services.store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
            $0.runtime = .known(runtime)
            $0.model = model
        }
        let log = DebugVoiceLog()
        let note = log.note
        note("runtime \(runtime.rawValue) model=\(model ?? "default")")
        let messages = Task {
            var seen: [UUID: CueMessage] = [:]
            do {
                for try await rows in workspace.services.store.observe({ try $0.cueMessages() }) {
                    for row in rows where seen[row.id] != row {
                        seen[row.id] = row
                        note("cue-message \(row.author.rawValue) delivered=\(row.deliveredAt != nil) \(row.text)")
                    }
                }
            } catch { note("cue-store-error \(error)") }
        }
        defer { messages.cancel() }
        guard let input = args.voice else { return await logPhoneCalls(workspace.services.voice, note: note) }
        for await canHear in Observations({ workspace.cue.canHear }) where canHear { break }
        var files: [URL] = []
        let fixture: VoiceFixture?
        if input == "mic" { fixture = nil } else {
            let url = URL(filePath: input)
            files = url.hasDirectoryPath ? ["first.wav", "interrupt.wav", "stop.wav"].map { url.appending(path: $0) } : [url]
            fixture = VoiceFixture(downlink: args.voiceOpts.record != nil ? .record : .discard)
        }
        workspace.toggleVoiceCall(source: fixture.map { .fixture($0) } ?? .microphone)
        guard let call = workspace.voice else { return }
        var replied = false, heardAfterReply = false, finishedAfterReply = false
        var assistantTurn: String?
        var replayed: Set<String> = []
        var requestCount = 0
        var stage = 0, submittedBeforeInput = 0
        var inputFinished = false, outputLoud = false
        var fixturePosted = false
        // 模型可把一个音频文件分成多个用户回合，Cue 也可回多条；阶段只按本次声源送完与其后的请求完成推进。
        func advance() {
            guard call.isLive else { return }
            if !fixturePosted, call.phase == .listening, let text = args.voiceOpts.readFixture {
                fixturePosted = true
                Task {
                    do { try await workspace.services.store.addCueMessage(.cue, text: text, answeredRequests: []) }
                    catch { note("fixture-error \(error)"); call.hangUp() }
                }
            }
            if heardAfterReply, finishedAfterReply, call.phase == .listening, args.voiceOpts.hangUpAfterReply {
                call.hangUp()
                return
            }
            guard let fixture, stage < files.count + 1 else { return }
            if stage == 0, call.phase == .listening {
            } else if stage == 1, files.count > 1, inputFinished, replied, outputLoud, call.phase == .speaking {
            } else if stage >= 2, inputFinished, requestCount > submittedBeforeInput, heardAfterReply, finishedAfterReply,
                      call.phase == .listening, call.userTurn == nil {
                if stage == files.count { call.hangUp(); return }
            } else { return }
            let file = files[stage]
            stage += 1
            inputFinished = false
            replied = false
            heardAfterReply = false
            finishedAfterReply = false
            submittedBeforeInput = requestCount
            note("play \(file.lastPathComponent)")
            do { try fixture.play(file) }
            catch { note("fixture-error \(error)"); call.hangUp() }
        }
        fixture?.finished = { file in
            note("input-ended \(file)")
            inputFinished = true
            advance()
        }
        call.mark = { mark in
            note(mark)
            if mark.hasPrefix("cue-sent ") {
                replied = true
                heardAfterReply = false
                finishedAfterReply = false
                if args.voiceOpts.replay {
                    for request in call.requests where !request.pending && replayed.insert(request.delegation.id).inserted {
                        let delegation = request.delegation
                        note("replay-after-result \(delegation.id)")
                        if let turn = delegation.turn {
                            call.inputs.continuation.yield(.wire(.success(.turn(id: turn, assistant: false, done: true, text: delegation.text))))
                        }
                        call.inputs.continuation.yield(.wire(.success(.delegation(delegation))))
                    }
                }
            }
            if mark.hasPrefix("handoff ") { requestCount += 1 }
            if mark.hasPrefix("assistant-turn ") { assistantTurn = String(mark.dropFirst("assistant-turn ".count)) }
            if let assistantTurn, replied, mark.hasPrefix("assistant-said \(assistantTurn) ") { finishedAfterReply = true }
            if mark == "output-loud" { outputLoud = true; if replied { heardAfterReply = true } }
            if mark.hasPrefix("output-quiet") { outputLoud = false }
            advance()
        }
        defer { call.mark = { _ in } }
        let limit = Task {
            await Task.wait(for: .seconds(args.voiceOpts.seconds ?? 60))
            if call.isLive { workspace.toggleVoiceCall() }
        }
        for await phase in Observations({ call.phase }) {
            note("phase \(phase)")
            advance()
            if !call.isLive { break }
        }
        limit.cancel()
        if let fixture, let record = args.voiceOpts.record {
            do { try fixture.write(to: URL(filePath: record)); note("recorded \(record)") }
            catch { note("record-error \(error)") }
        }
        note("end \(call.phase) audioMs=\(call.audioMs) usedPercent=\(call.usedPercent.map { "\($0)" } ?? "-")")
        if !args.voiceOpts.keepOpen { Task { NSApp.terminate(nil) } }
    }

    /// 手机发起的通话由这台的 VoiceCall 持有（媒体在手机）：照样记节点与阶段，直到实例退出。
    private static func logPhoneCalls(_ voice: VoiceService, note: @escaping (String) -> Void) async {
        for await call in Observations({ voice.call }) {
            guard let call else { continue }
            call.mark = note
            for await phase in Observations({ call.phase }) {
                note("phase \(phase)")
                if phase == .ended || phase.isFailure { note("end \(phase) audioMs=\(call.audioMs)") }
            }
        }
    }
}
#endif
