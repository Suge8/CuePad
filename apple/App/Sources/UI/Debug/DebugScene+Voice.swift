#if os(macOS) && DEBUG
import AppKit
import CueStore
import Foundation

/// 和 Cue 通话的验收（`xc.sh run mac` 起的实例没有菜单栏，菜单那一项点不到，这里调它的同一个动作 `Workspace.toggleVoiceCall`）：
/// - 给了 `-CuePadVoiceToken <文件>`（令牌由 `scripts/voice-token.py` 经本机 Codex app-server 获取，`DebugHooks.voiceToken`）就让 Cue 在这台启用。
///   配了 `-CuePadCueBrain apple/scripts/cue-brain-stub.py` 时运行时是 Pi、大脑是替身（回 `CUE_STUB_REPLY` 那句）；没配时是真的 Claude Code，
///   `-CuePadVoiceRuntime <pi|codex|claude>`、`-CuePadVoiceModel <模型>` 可指定其他已在隔离目录登录的运行时。
///   登录照 docs/verify.md「让 Cue 真跑」在起实例前交给它（`CLAUDE_CODE_OAUTH_TOKEN`）。
/// - `-CuePadVoice mic`：Cue 能听了就开始通话，声音走麦克风与扬声器（人工验收）；`-CuePadVoice <音频文件>`：接通后播一次这个文件当你说的话，
///   `-CuePadVoiceDevice <设备名片段>` 指定麦克风设备（不改变系统默认输入）；不指定时使用默认输入。
///   对方的声音录到 `-CuePadVoiceRecord <wav>`（不外放；无人值守）。
/// - `-CuePadVoiceLoopback <目录>` 以本进程 tap 做临时麦克风（`VoiceLoopback`），按节点播 first.wav、interrupt.wav、stop.wav；退出前销毁设备。
///   单变量音频处理对照与本地电平模式见 `DebugVoice`；原始控制事件（不含音频块）写到 `-CuePadVoiceWireLog <文件>`。
/// - `-CuePadVoiceReadFixture <原文>` 把原文作为隔离库的主动消息请 GPT Live 朗读，录成后续验收的声源；不使用系统 TTS。
/// - 到 `-CuePadVoiceSeconds`（默认 60）挂断；配 `-CuePadVoiceHangUpAfterReply YES` 时，结果送出后观察到实际输出、模型回合结束且音轨安静才挂断。
///   `-CuePadVoiceReplay YES` 在 Cue 结果送出后重放原 delegation 与用户 turn.done，核对请求没有重复落库。
/// - 每个节点一行写进 `-CuePadVoiceLog <文件>`：`<距起点秒> <节点>`。`cue-forward` 是落库结果与交接归属，`cue-sent` 是发送完成，
///   `context-accepted` 是服务端追加回执，`assistant-said` 只是模型转写；真正出声要核对 `output-loud/quiet` 与输出录音。最后一行是终态与音频用量。
extension DebugScene {
    static func voiceCallIfAsked(_ workspace: Workspace) async {
        guard defaults.string(forKey: "CuePadVoiceToken") != nil else { return }
        await running("语音通话") { try await voiceCall(workspace) }
    }

    private static func voiceCall(_ workspace: Workspace) async throws {
        let host = workspace.services.hostID
        let runtime = defaults.string(forKey: "CuePadVoiceRuntime").flatMap(AgentKind.init(rawValue:))
            ?? (DebugHooks.cueBrain == nil ? .claudeCode : .pi)
        let model = defaults.string(forKey: "CuePadVoiceModel")
        try await workspace.services.store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
            $0.runtime = .known(runtime)
            $0.model = model
        }
        guard let input = defaults.string(forKey: "CuePadVoice") else { return }
        for await canHear in Observations({ workspace.cue.canHear }) where canHear { break }
        let log = defaults.string(forKey: "CuePadVoiceLog").map { URL(filePath: $0) }
        let started = Date.now
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(String(format: "%.3f ", Date.now.timeIntervalSince(started)) + line)
            if let log { try? lines.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8) }
        }
        let loopback: VoiceLoopback?
        if let directory = defaults.string(forKey: "CuePadVoiceLoopback") {
            loopback = try VoiceLoopback(directory: URL(filePath: directory))
            try await loopback?.start()
        } else { loopback = nil }
        defer {
            if let loopback {
                note("tap-peak \(loopback.peak)")
                do { try loopback.close(); note("loopback-removed") }
                catch { note("loopback-cleanup-error \(error)") }
            }
        }
        if let loopback, defaults.bool(forKey: "CuePadVoiceMeter") {
            try await DebugVoice.meter(loopback, note: note)
            // 先执行 defer 销毁公开设备，再退出实例。
            Task { NSApp.terminate(nil) }
            return
        }
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
        let source: VoicePeer.Source = input == "mic" ? .microphone(device: loopback?.name ?? defaults.string(forKey: "CuePadVoiceDevice")) : .file(URL(filePath: input))
        workspace.toggleVoiceCall(source: source, recording: defaults.string(forKey: "CuePadVoiceRecord").map { URL(filePath: $0) })
        guard let call = workspace.voice else { return }
        var replied = false, heardAfterReply = false, finishedAfterReply = false
        var assistantTurn: String?
        var replayed: Set<String> = []
        var requestCount = 0
        var stage = 0, submittedBeforeInput = 0
        var inputFinished = false, outputLoud = false
        var fixturePosted = false
        // 模型可把一个音频文件分成多个用户回合，Cue 也可回多条；阶段只按本次声源播完与其后的请求完成推进。
        func advance() {
            guard call.isLive else { return }
            if !fixturePosted, call.phase == .listening, let text = defaults.string(forKey: "CuePadVoiceReadFixture") {
                fixturePosted = true
                Task {
                    do { try await workspace.services.store.addCueMessage(.cue, text: text, answeredRequests: []) }
                    catch { note("fixture-error \(error)"); call.hangUp() }
                }
            }
            if heardAfterReply, finishedAfterReply, call.phase == .listening, defaults.bool(forKey: "CuePadVoiceHangUpAfterReply") {
                call.hangUp()
                return
            }
            guard let loopback else { return }
            let file: String
            if stage == 0, call.phase == .listening { file = "first.wav" }
            else if stage == 1, inputFinished, replied, outputLoud, call.phase == .speaking { file = "interrupt.wav" }
            else if stage >= 2, inputFinished, requestCount > submittedBeforeInput, heardAfterReply, finishedAfterReply,
                    call.phase == .listening, call.userTurn == nil {
                if stage == 3 { call.hangUp(); return }
                file = "stop.wav"
            } else { return }
            stage += 1
            inputFinished = false
            replied = false
            heardAfterReply = false
            finishedAfterReply = false
            submittedBeforeInput = requestCount
            note("play \(file)")
            do { try loopback.play(file) }
            catch { note("loopback-error \(error)"); call.hangUp() }
        }
        loopback?.onFinished = { file, succeeded in
            note("input-finished \(file) success=\(succeeded)")
            guard succeeded else { call.hangUp(); return }
            inputFinished = true
            advance()
        }
        call.mark = { mark in
            note(mark)
            if mark.hasPrefix("cue-sent ") {
                replied = true
                heardAfterReply = false
                finishedAfterReply = false
                if defaults.bool(forKey: "CuePadVoiceReplay") {
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
        defer { call.mark = { _ in }; loopback?.onFinished = { _, _ in } }
        let limit = Task {
            await Task.wait(for: .seconds(seconds("CuePadVoiceSeconds", default: 60)))
            if call.isLive { workspace.toggleVoiceCall() }
        }
        for await phase in Observations({ call.phase }) {
            note("phase \(phase)")
            advance()
            if !call.isLive { break }
        }
        limit.cancel()
        note("end \(call.phase) audioMs=\(call.audioMs) usedPercent=\(call.usedPercent.map { "\($0)" } ?? "-")")
        Task { NSApp.terminate(nil) }
    }
}
#endif
