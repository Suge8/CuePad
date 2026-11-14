#if os(macOS)
import CueStore
import Foundation

extension VoiceService {
    /// 这台 Mac 的完整投影：本机界面直接用它，发给手机的是 `bounded()` 后的那份。
    /// 通话结束后库读不了时，结果已跟不上，阶段报资料库不可用。
    func fullProjection(_ call: VoiceCall) throws -> VoiceCallProjection {
        let record = call.record
        let phase: VoiceCallProjection.Phase = switch call.phase {
        case .connecting: .connecting
        case .listening: .listening
        case .speaking: .speaking
        case .closing: .closing
        case .ended: record.storeFailure == nil ? .ended(reason: .hungUp) : .failed(.storageUnavailable)
        case .failed(let failure): .failed(Self.issue(for: failure))
        }
        let requests = record.requests.map { request in
            VoiceCallProjection.Request(id: request.rowID,
                reference: request.message.map { .recorded(message: $0) } ?? .unrecorded(session: request.origin, request: request.rowID),
                recording: request.isRecording, issue: request.failure == nil ? nil : .storageUnavailable,
                preview: request.message == nil ? .init(original: request.text) : nil)
        }
        let replies = record.replies.map { reply in
            let state: VoiceCallProjection.Readback = switch reply.delivery {
            case .awaitingOrigin: .awaitingOrigin
            case .queued: .queued
            case .sending: .sending
            case .submitted: .submitted
            case .unconfirmed: .unconfirmed
            }
            return VoiceCallProjection.Reply(message: reply.id, readback: state)
        }
        let ids = record.requests.compactMap(\.message)
        var executions: [VoiceCallProjection.Execution] = []
        func stop(_ session: String) -> UUID? { record.stopRequests.last { $0.stopTurn?.sessionID == session }?.id }
        for item in record.executions {
            let session = item.state.sessionID
            var turn: TurnTarget?
            if item.state.canStop, let started = services.bridge.session(sessionID: session)?.turnStartedAt {
                do { turn = try services.store.snapshot { try $0.voiceExecutionTarget(session, requests: ids, turnStartedAt: started) }.value }
                catch CueStoreError.turnChanged {}
            }
            executions.append(.init(session: session, turn: turn, stop: stop(session)))
        }
        for request in record.stopRequests {
            guard let session = request.stopTurn?.sessionID, !executions.contains(where: { $0.session == session }) else { continue }
            executions.append(.init(session: session, turn: nil, stop: stop(session)))
        }
        return VoiceCallProjection(session: VoiceSessionID(call.session), phase: phase, requests: requests, replies: replies, executions: executions,
                     response: !call.assistantTurns.isEmpty ? .assistantTurn : call.waitingForResponse ? .awaitingAssistant : .none, canRepeat: call.canRepeat)
    }

    static func issue(for failure: VoiceCall.Failure) -> VoiceIssue {
        switch failure {
        case .codex(.notInstalled): .codexNotInstalled
        case .codex(.signedOut), .wire(.signedOut): .signedOut
        case .codex(.unresponsive): .codexUnresponsive
        case .wire(.notAllowed(let status)): .notAllowed(status: status)
        case .wire(.server(let status, _)): .server(status: status)
        case .microphoneDenied: .ended(.permissionDenied)
        case .timedOut: .ended(.timedOut)
        case .media(let reason): .ended(reason)
        case .wire(.malformed): .ended(.protocolRejected)
        case .closed, .server, .other: .ended(.controlFailed)
        }
    }
}
#endif
