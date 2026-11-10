#if os(macOS)
import CueStore
import Foundation

extension VoiceService {
    func macProjection(_ call: VoiceCall) throws -> VoiceCallProjection { try fullProjection(call).bounded() }

    func fullProjection(_ call: VoiceCall) throws -> VoiceCallProjection {
        let phase: VoiceCallProjection.Phase = switch call.phase {
        case .connecting: .connecting
        case .listening: .listening
        case .handingOff: .processing
        case .speaking: .speaking
        case .closing: .closing
        case .ended: .ended(reason: .hungUp)
        case .failed(let failure): .failed(Self.issue(for: failure))
        }
        let requests = call.requests.map { request in
            VoiceCallProjection.Request(id: request.rowID,
                reference: request.message.map { .recorded(message: $0) } ?? .unrecorded(session: request.origin, request: request.rowID),
                recording: request.isRecording, issue: request.failure == nil ? nil : .storageUnavailable,
                preview: request.message == nil ? .init(original: request.text) : nil)
        }
        let replies = call.replies.map { reply in
            let state: VoiceCallProjection.Readback = switch reply.delivery {
            case .awaitingOrigin: .awaitingOrigin
            case .queued: .queued
            case .sending: .sending
            case .submitted: .submitted
            case .unconfirmed: .unconfirmed
            }
            return VoiceCallProjection.Reply(message: reply.id, readback: state)
        }
        var targets: [VoiceExecutionTarget] = []
        for execution in call.executions where execution.state.canStop {
            guard let turn = services.pi.session(sessionID: execution.state.sessionID)?.turnStartedAt else { continue }
            for request in call.requests.compactMap(\.message) {
                do {
                    let snapshot = try services.store.snapshot {
                        try $0.voiceExecutionTarget(execution.state.sessionID, requests: [request], turnStartedAt: turn)
                    }
                    targets.append(.init(request: request, turn: snapshot.value))
                    break
                } catch CueStoreError.cannotStop { continue }
            }
        }
        targets.sort {
            if $0.turn.turnStartedAtMilliseconds != $1.turn.turnStartedAtMilliseconds {
                return $0.turn.turnStartedAtMilliseconds < $1.turn.turnStartedAtMilliseconds
            }
            return $0.turn.deliveryID.uuidString < $1.turn.deliveryID.uuidString
        }
        return VoiceCallProjection(session: VoiceSessionID(call.session), phase: phase, requests: requests, replies: replies, executions: targets,
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
