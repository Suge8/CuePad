#if os(iOS)
import CueStore
import SwiftUI

/// 手机通话的呈现宿主。共享视图只读这份投影并发出带原引用的动作；媒体仍由 VoiceService 持有。
/// 原聊天按 UUID 订阅，不受聊天页面最近 200 条的限制。未落库请求没有正文，不得用其他消息代替。
struct PhoneVoiceHost<Content: View>: View {
    @Environment(Workspace.self) private var workspace
    @State private var messages: [CueMessage]?
    let content: (PhoneVoiceViewState, @escaping (PhoneVoiceAction) async throws -> VoiceCommandResult.Outcome?) -> Content

    var body: some View {
        let phone = workspace.phoneVoice
        let ids = phone.messageIDs
        content(PhoneVoiceViewState(phone: phone, messages: messages ?? []), act)
            .observing(workspace.services.store, id: ids, into: $messages, onError: workspace.fail) {
                try $0.cueMessages(ids)
            }
    }

    private func act(_ action: PhoneVoiceAction) async throws -> VoiceCommandResult.Outcome? {
        switch action {
        case .start:
            try await workspace.startVoiceCall()
        case .hangUp:
            await workspace.hangUpVoiceCall()
        case .setMuted(let muted):
            try await workspace.setVoiceMuted(muted)
        case .recover(let reference):
            return try await workspace.recoverVoiceRequest(reference, command: UUID())
        case .repeatReply(let message):
            return try await workspace.repeatVoiceReply(message, command: UUID())
        case .stop(let target):
            return try await workspace.stopVoiceExecution(target, command: UUID())
        }
        return nil
    }
}

/// 命令结果原样返回，包括拒绝原因；调用方必须展示结果或传输失败，不自动重发。
enum PhoneVoiceAction {
    case start, hangUp
    case setMuted(Bool)
    case recover(VoiceRequestReference)
    case repeatReply(UUID)
    case stop(VoiceExecutionTarget)
}

struct PhoneVoiceViewState {
    struct Request: Identifiable {
        let reference: VoiceRequestReference
        let message: CueMessage?
        let recording: Bool
        let issue: VoiceIssue?
        var id: VoiceRequestReference { reference }
    }

    struct Reply: Identifiable {
        let id: UUID
        let message: CueMessage?
        let readback: VoiceCallProjection.Readback
    }

    let phase: VoiceCallProjection.Phase?
    let response: VoiceCallProjection.Response
    let muted: Bool
    let canMute: Bool
    let startUnavailableReason: VoiceIssue?
    let samples: () -> [Double]
    let requests: [Request]
    let replies: [Reply]
    let executions: [VoiceExecutionTarget]

    init(phone: VoicePhonePresentation, messages: [CueMessage]) {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        phase = phone.phase
        response = phone.response
        muted = phone.muted
        canMute = phone.canMute
        startUnavailableReason = phone.startUnavailableReason
        samples = phone.samples
        requests = phone.requests.map { request in
            let message: CueMessage?
            switch request.reference {
            case .recorded(let id): message = byID[id]
            case .unrecorded: message = nil
            }
            return Request(reference: request.reference, message: message, recording: request.recording, issue: request.issue)
        }
        replies = phone.replies.map { Reply(id: $0.message, message: byID[$0.message], readback: $0.readback) }
        executions = phone.executions
    }
}

private extension VoicePhonePresentation {
    var messageIDs: [UUID] {
        let requests = requests.compactMap { request -> UUID? in
            if case .recorded(let id) = request.reference { return id }
            return nil
        }
        return Array(Set(requests + replies.map(\.message))).sorted { $0.uuidString < $1.uuidString }
    }
}
#endif
