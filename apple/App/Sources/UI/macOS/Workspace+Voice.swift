#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 和 Cue 通话的动作入口；通话、真实请求与结果在 VoiceCall，执行控制沿用现有投送链路。
/// 交出来的话走"对 Cue 说"同一个入口（`speak` 到 `.cue`），所以 Cue 没启用（听不到）时不起通话。
extension Workspace {
    /// 菜单的动作；无人值守与人工验收（`DebugScene.voiceCallIfAsked`）走同一个，只换声音来源与录音。
    func toggleVoiceCall(source: VoicePeer.Source = .microphone(device: nil), recording: URL? = nil) {
        if let voice, voice.isLive { return voice.hangUp() }
        startVoiceCall(source: source, recording: recording)
    }

    func startVoiceCall(
        source: VoicePeer.Source = .microphone(device: nil), recording: URL? = nil,
        makeCall: @MainActor (VoiceCall.Dependencies) -> VoiceCall = DebugHooks.makeVoiceCall
    ) {
        showCue()
        guard voice?.isLive != true else { return }
        guard cue.canHear else { return say("Cue 还没启用，启用后才能通话", tone: .failure) }
        // 常驻通话栏呈现连接、回应和失败；浮动提示会遮住声纹与挂断入口。
        services.voice.startLocal(source: source, recording: recording, name: cue.name, makeCall: makeCall)
    }

    /// 真实会话的既有投影；选择范围后只停那个会话的当前回合，不把 Cue 的话当作执行确认。
    var voiceExecutions: [PiSessionListItem] { voice?.executions ?? [] }

    func stopVoiceExecution(_ sessionID: String) async throws -> DeliveryRequest {
        guard let voice else { throw CueStoreError.notFound }
        guard let turn = services.pi.session(sessionID: sessionID)?.turnStartedAt else { throw CueStoreError.cannotStop(sessionID) }
        let ids = voice.requests.compactMap(\.message)
        let target = try await services.store.voiceExecutionTarget(sessionID, requests: ids, turnStartedAt: turn)
        let request = try await services.store.stopVoiceExecution(target, requests: ids)
        if !voice.stopRequests.contains(where: { $0.id == request.id }) { voice.stopRequests.append(request) }
        voice.watchRequests()
        return services.uploaded(request)
    }

    /// 恢复携带原对象身份；界面投影之后状态可能变化，仍由原重试入口核验，不改选别的请求。
    func recoverVoice(_ recovery: CueVoicePresentation.Recovery) async throws {
        switch recovery {
        case .retryRequest(let id): try await retryVoiceRequest(id)
        case .repeatReply(let id): try await services.voice.command(.repeatReply(message: id)).requireAccepted()
        case .reconnect: startVoiceCall()
        }
    }

    func retryVoiceRequest(_ id: String) async throws {
        guard let voice, let request = voice.requests.first(where: { $0.id == id }) else { throw CueStoreError.notFound }
        let reference: VoiceRequestReference = request.message.map { .recorded(message: $0) }
            ?? .unrecorded(session: request.origin, request: request.rowID)
        try await services.voice.command(.recover(request: reference)).requireAccepted()
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
        case .microphoneDenied: String(localized: "麦克风权限未开启：在系统设置中允许 CuePad 使用麦克风后重新接通")
        case .timedOut: String(localized: "通话连接或发送超时，请重新接通；已有请求和回复仍然保留")
        case .media: String(localized: "通话的声音连接断了")
        case .closed(let reason): String(localized: "通话断开了：\(reason)")
        case .server(let message): String(localized: "通话出错：\(message)")
        case .other(let message): String(localized: "通话出错：\(message)")
        }
    }
}
#endif
