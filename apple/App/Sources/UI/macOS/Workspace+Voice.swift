#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 和 Cue 通话的入口（菜单"文件 › 和 Cue 通话"，再点一次挂断）：通话本身在 `VoiceCall`，这里只起、挂与用提示条报它到了哪一步。
/// 交出来的话走"对 Cue 说"同一个入口（`speak` 到 `.cue`），所以 Cue 没启用（听不到）时不起通话。
extension Workspace {
    /// 菜单的动作；无人值守与人工验收（`DebugScene.voiceCallIfAsked`）走同一个，只换声音来源与录音。
    func toggleVoiceCall(source: VoicePeer.Source = .microphone, recording: URL? = nil) {
        if let voice, voice.isLive { return voice.hangUp() }
        guard cue.canHear else { return say("Cue 还没启用，启用后才能通话", tone: .failure) }
        let services = services
        let call = VoiceCall(VoiceCall.Dependencies(
            access: DebugHooks.voiceToken.map { file in { try Self.access(reading: file) } }
                ?? { try await services.agents.integration.codexAccess(executable: services.agents.executable(.codex)) },
            tell: { [weak self] text in self?.speak(StoredBody.make(text: text, files: []), to: .cue) },
            store: services.store, cueName: cue.name, source: source, recording: recording))
        voice = call
        Task { await call.run() }
        Task { [weak self] in
            for await phase in Observations({ call.phase }) {
                self?.announce(phase)
                if !call.isLive { break }
            }
        }
    }

    /// 令牌文件（`DebugHooks.voiceToken`）里的那一个
    private static func access(reading file: URL) throws -> CodexAccess {
        guard let access = CodexAccess(token: try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CodexAccessError.signedOut
        }
        return access
    }

    private func announce(_ phase: VoiceCall.Phase) {
        switch phase {
        case .connecting: say("正在接通 Cue…")
        case .listening: say("通话中")
        case .handingOff, .speaking: break
        case .ended: say("通话已结束")
        case .failed(let failure): say(Dotted(failure.shown), tone: .failure)
        }
    }
}

extension VoiceCall.Failure {
    /// 提示条上的那句
    var shown: String {
        switch self {
        case .codex(.notInstalled): String(localized: "通话要用 Codex 的 ChatGPT 登录：这台 Mac 没装 Codex")
        case .codex(.signedOut), .wire(.signedOut): String(localized: "Codex 的 ChatGPT 登录不可用或已过期：在 Codex 里重新登录后再通话")
        case .wire(.notAllowed(let status)): String(localized: "ChatGPT 拒绝了这次通话（\(status)）：套餐不含语音或额度已用完")
        case .wire(.server(let status, _)): String(localized: "通话没能建立（\(status)）")
        case .wire(.malformed): String(localized: "通话没能建立：服务器的回应认不出")
        case .media: String(localized: "通话的声音连接断了")
        case .closed(let reason): String(localized: "通话断开了：\(reason)")
        case .server(let message): String(localized: "通话出错：\(message)")
        case .other(let message): String(localized: "通话出错：\(message)")
        }
    }
}
#endif
