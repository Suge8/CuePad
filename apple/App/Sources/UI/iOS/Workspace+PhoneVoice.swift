#if os(iOS)
import Foundation

/// 手机宿主的展示/动作接口；详情正文按这里的 UUID 从原聊天读取，不从信令建立第二份聊天。
/// phase 由 owner 提供，音量只在声音叶子调用 samples；离开 Cue 页无需调用任何结束动作。
struct VoicePhonePresentation {
    let phase: VoiceCallProjection.Phase?
    let response: VoiceCallProjection.Response
    let muted: Bool
    let canMute: Bool
    let startUnavailableReason: VoiceIssue?
    let samples: () -> [Double]
    let requests: [VoiceCallProjection.Request]
    let replies: [VoiceCallProjection.Reply]
    let executions: [VoiceExecutionTarget]
    let omitted: VoiceCallProjection.Omitted
    let commandResults: [VoiceCommand.ID: VoiceCommandResult.Outcome]
}

extension Workspace {
    var phoneVoice: VoicePhonePresentation {
        let voice = services.voice
        return .init(phase: voice.phase, response: voice.projection?.response ?? .none, muted: voice.isMuted, canMute: voice.canMute,
                     startUnavailableReason: cue.canHear ? voice.startUnavailableReason : .cueUnavailable,
                     samples: { voice.samples }, requests: voice.projection?.requests ?? [], replies: voice.projection?.replies ?? [],
                     executions: voice.projection?.executions ?? [], omitted: voice.projection?.omitted ?? .init(), commandResults: voice.commandResults)
    }

    func startVoiceCall() async throws { try await services.voice.start() }
    func hangUpVoiceCall() async { await services.voice.end() }
    func setVoiceMuted(_ value: Bool) async throws { try await services.voice.setMuted(value) }

    /// 每次点击在调用处生成 UUID；保留它可查询该动作的确认结果，断线后不自动重发。
    @discardableResult
    func recoverVoiceRequest(_ reference: VoiceRequestReference, command: UUID) async throws -> VoiceCommandResult.Outcome {
        try await services.voice.command(.recover(request: reference), id: command)
    }

    @discardableResult
    func repeatVoiceReply(_ message: UUID, command: UUID) async throws -> VoiceCommandResult.Outcome {
        try await services.voice.command(.repeatReply(message: message), id: command)
    }

    @discardableResult
    func stopVoiceExecution(_ target: VoiceExecutionTarget, command: UUID) async throws -> VoiceCommandResult.Outcome {
        try await services.voice.command(.stop(target: target), id: command)
    }
}
#endif
