#if os(macOS) && DEBUG
import AppKit
import CuePi
import CueStore
import Foundation

/// `-CuePadVoice <音频文件>`：无人值守地打一通和 Cue 的电话（`Workspace.startVoiceCall`）。Cue 在这台启用、运行时 Pi（大脑配 `-CuePadCueBrain` 换成替身），
/// 声音来源是这个文件（接通后播一次），对方的声音录到 `-CuePadVoiceRecord <wav>`；令牌从 `-CuePadVoiceToken <文件>` 读（隔离目录里的 Codex 没登录，
/// 文件由脚本向本机 Codex 只读地要来）。Cue 回话之后模型念完（回到聆听）再等 1 秒挂断，或到 `-CuePadVoiceSeconds`（默认 60）挂断，挂完退出。
/// 每个节点一行写进 `-CuePadVoiceLog <文件>`：`<距起点秒> <节点>`，最后一行是终态与音频用量。
extension DebugScene {
    static func voiceCallIfAsked(_ workspace: Workspace) async {
        guard let input = defaults.string(forKey: "CuePadVoice") else { return }
        await running("语音通话") { try await voiceCall(workspace, input: URL(filePath: input)) }
    }

    private static func voiceCall(_ workspace: Workspace, input: URL) async throws {
        let services = workspace.services
        let host = services.hostID
        try await services.store.updateCueProfile {
            $0.hostID = host
            $0.enabledAt = .now
            $0.runtime = .known(.pi)
        }
        let tokenFile = defaults.string(forKey: "CuePadVoiceToken").map { URL(filePath: $0) }
        let log = defaults.string(forKey: "CuePadVoiceLog").map { URL(filePath: $0) }
        let started = Date.now
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(String(format: "%.3f ", Date.now.timeIntervalSince(started)) + line)
            if let log { try? lines.joined(separator: "\n").appending("\n").write(to: log, atomically: true, encoding: .utf8) }
        }
        let call = workspace.startVoiceCall(source: .file(input), recording: defaults.string(forKey: "CuePadVoiceRecord").map { URL(filePath: $0) }) {
            guard let tokenFile, let access = CodexAccess(token: try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw CodexAccessError.signedOut }
            return access
        }
        var replied = false
        call.mark = { mark in
            note(mark)
            if mark == "cue-reply" { replied = true }
        }
        let limit = Task {
            await Task.wait(for: .seconds(seconds("CuePadVoiceSeconds", default: 60)))
            call.hangUp()
        }
        for await phase in Observations({ call.phase }) {
            note("phase \(phase)")
            if replied, phase == .listening, defaults.bool(forKey: "CuePadVoiceHangUpAfterReply") {
                await Task.wait(for: .seconds(1))
                call.hangUp()
            }
            if !call.isLive { break }
        }
        limit.cancel()
        note("end \(call.phase) audioMs=\(call.audioMs) usedPercent=\(call.usedPercent.map { "\($0)" } ?? "-")")
        NSApp.terminate(nil)
    }
}
#endif
