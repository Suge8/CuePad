#if os(iOS)
import CueStore
import SwiftUI
import UIKit

/// 手机通话的呈现宿主。共享视图只读这份投影并发出带原引用的动作；媒体仍由 VoiceService 持有。
/// 原聊天按 UUID 订阅，不受聊天页面最近 200 条的限制。未落库请求没有正文，不得用其他消息代替。
struct PhoneVoiceHost<Content: View>: View {
    @Environment(Workspace.self) private var workspace
    @State private var records: PhoneVoiceRecords?
    let content: (PhoneVoiceViewState, @escaping (PhoneVoiceAction) async throws -> VoiceCommandResult.Outcome?) -> Content

    var body: some View {
        let phone = workspace.phoneVoice
        let ids = phone.recordIDs
        content(PhoneVoiceViewState(phone: phone, records: records, shown: { workspace.shownInHeader($0.state, delivery: nil) }), workspace.performPhoneVoice)
            .observing(workspace.services.store, id: ids, into: $records, onError: workspace.fail) { store in
                try PhoneVoiceRecords(messages: store.cueMessages(ids.messages), executions: store.piSessions(sessionIDs: ids.sessions))
            }
    }
}

extension Workspace {
    var phoneVoiceViewState: PhoneVoiceViewState {
        PhoneVoiceViewState(phone: phoneVoice, records: nil, shown: { shownInHeader($0.state, delivery: nil) })
    }

    func performPhoneVoice(_ action: PhoneVoiceAction) async throws -> VoiceCommandResult.Outcome? {
        switch action {
        case .start:
            try await startVoiceCall()
        case .hangUp:
            await hangUpVoiceCall()
        case .setMuted(let muted):
            try await setVoiceMuted(muted)
        case .recover(let reference):
            return try await recoverVoiceRequest(reference, command: UUID())
        case .repeatReply(let message):
            return try await repeatVoiceReply(message, command: UUID())
        case .stop(let target):
            return try await stopVoiceExecution(target, command: UUID())
        case .microphoneSettings:
            guard await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) else { throw VoiceIssue.ended(.permissionDenied) }
        }
        return nil
    }
}

/// 命令结果原样返回，包括拒绝原因；调用方必须展示结果或传输失败，不自动重发。
enum PhoneVoiceAction {
    case start, hangUp, microphoneSettings
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

    struct Execution: Identifiable {
        let target: VoiceExecutionTarget
        /// 同步记录尚未到达时为 nil，不能拿内部标识当标题。
        let title: String?
        let status: PiShown?
        var id: VoiceExecutionTarget { target }
    }

    let phase: VoiceCallProjection.Phase?
    let response: VoiceCallProjection.Response
    let muted: Bool
    let canMute: Bool
    let startUnavailableReason: VoiceIssue?
    let samples: () -> [Double]
    let requests: [Request]
    let replies: [Reply]
    let executions: [Execution]

    fileprivate init(phone: VoicePhonePresentation, records: PhoneVoiceRecords?, shown: (PiSessionListItem) -> PiShown) {
        let byID = Dictionary(uniqueKeysWithValues: (records?.messages ?? []).map { ($0.id, $0) })
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
        executions = phone.executions.map { target in
            let item = records?.executions[target.turn.sessionID]
            return Execution(target: target, title: item.map { $0.task?.title ?? $0.state.title }, status: item.map(shown))
        }
    }
}

private nonisolated struct PhoneVoiceRecords: Equatable, Sendable {
    let messages: [CueMessage]
    let executions: [String: PiSessionListItem]
}

private nonisolated struct PhoneVoiceRecordIDs: Equatable, Sendable {
    let messages: [UUID]
    let sessions: [String]
}

private extension VoicePhonePresentation {
    var recordIDs: PhoneVoiceRecordIDs {
        let requests = requests.compactMap { request -> UUID? in
            if case .recorded(let id) = request.reference { return id }
            return nil
        }
        return PhoneVoiceRecordIDs(
            messages: Array(Set(requests + replies.map(\.message))).sorted { $0.uuidString < $1.uuidString },
            sessions: Array(Set(executions.map(\.turn.sessionID))).sorted())
    }
}
#endif
