#if os(macOS) && DEBUG
import AppKit
import CueStore
import Foundation

/// 和 Cue 通话的验收（`xc.sh run mac` 起的实例没有菜单栏，菜单那一项点不到，这里调它的同一个动作 `Workspace.toggleVoiceCall`）：
/// - 给了 `-CuePadVoiceToken <文件>`（令牌由 `scripts/voice-token.py` 向本机 Codex 只读地要，`DebugHooks.voiceToken`）就让 Cue 在这台启用。
///   配了 `-CuePadCueBrain apple/scripts/cue-brain-stub.py` 时运行时是 Pi、大脑是替身（回 `CUE_STUB_REPLY` 那句）；没配时是真的 Claude Code，
///   登录照 docs/verify.md「让 Cue 真跑」在起实例前交给它（`CLAUDE_CODE_OAUTH_TOKEN`）。
/// - `-CuePadVoice mic`：Cue 能听了就开始通话，声音走麦克风与扬声器（人工验收）；`-CuePadVoice <音频文件>`：接通后播一次这个文件当你说的话，
///   `-CuePadVoiceDevice <设备名片段>` 指定麦克风设备（不改变系统默认输入）；不指定时使用默认输入。
///   对方的声音录到 `-CuePadVoiceRecord <wav>`（不外放；无人值守）。
/// - 到 `-CuePadVoiceSeconds`（默认 60）挂断；配 `-CuePadVoiceHangUpAfterReply YES` 时 Cue 回话念完（回到聆听）1 秒后就挂。挂断也走 `toggleVoiceCall`，挂完退出。
/// - 每个节点一行写进 `-CuePadVoiceLog <文件>`：`<距起点秒> <节点>`（含每轮说完的转写），最后一行是终态与音频用量。
extension DebugScene {
    static func voiceCallIfAsked(_ workspace: Workspace) async {
        guard defaults.string(forKey: "CuePadVoiceToken") != nil else { return }
        await running("语音通话") { try await voiceCall(workspace) }
    }

    private static func voiceCall(_ workspace: Workspace) async throws {
        let host = workspace.services.hostID
        let runtime: AgentKind = DebugHooks.cueBrain == nil ? .claudeCode : .pi
        try await workspace.services.store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
            $0.runtime = .known(runtime)
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
        let source: VoicePeer.Source = input == "mic" ? .microphone(device: defaults.string(forKey: "CuePadVoiceDevice")) : .file(URL(filePath: input))
        workspace.toggleVoiceCall(source: source, recording: defaults.string(forKey: "CuePadVoiceRecord").map { URL(filePath: $0) })
        guard let call = workspace.voice else { return }
        var replied = false
        call.mark = { mark in
            note(mark)
            if mark == "cue-reply" { replied = true }
        }
        let limit = Task {
            await Task.wait(for: .seconds(seconds("CuePadVoiceSeconds", default: 60)))
            if call.isLive { workspace.toggleVoiceCall() }
        }
        for await phase in Observations({ call.phase }) {
            note("phase \(phase)")
            if replied, phase == .listening, defaults.bool(forKey: "CuePadVoiceHangUpAfterReply") {
                await Task.wait(for: .seconds(1))
                if call.isLive { workspace.toggleVoiceCall() }
            }
            if !call.isLive { break }
        }
        limit.cancel()
        note("end \(call.phase) audioMs=\(call.audioMs) usedPercent=\(call.usedPercent.map { "\($0)" } ?? "-")")
        NSApp.terminate(nil)
    }
}
#endif
