import CueStore
import Foundation
import os

extension VoiceService {
    /// 一次明确点击一个 UUID；传输失败只报告未确认，绝不在换租约后自动重发。
    func command(_ action: VoiceCommand.Action, id: UUID = UUID()) async throws -> VoiceCommandResult.Outcome {
        let command = VoiceCommand(id: .init(id), action: action)
        if let result = commandResults[command.id] { return result }
        #if os(macOS)
        let outcome = await execute(command, mediaSession: call.map { VoiceSessionID($0.session) })
        #else
        guard pending[command.id] == nil else { throw VoiceIssue.busy }
        guard let signaling, let session, case .ready(let local) = signaling.voiceAvailability else { throw VoiceSignalError.unavailable }
        let scope = VoiceOperationScope()
        defer { scope.end(); pending[command.id] = nil }
        let outcome = try await scope.perform(within: .seconds(30)) {
            guard let host = try await self.services.store.cueProfile()?.activeHost else { throw VoiceIssue.cueUnavailable }
            let peer = try await signaling.resolveVoicePeer(VoiceDeviceID(host))
            guard signaling.voiceAvailability == .ready(endpoint: local) else { throw VoiceSignalError.leaseChanged }
            return try await scope.wait { finish in
                self.pending[command.id] = Pending(session: session, peer: peer, local: local, finish: finish)
                scope.spawn {
                    do { try await signaling.sendVoice(.command(command: command), session: session, to: peer) }
                    catch { finish(.failure(error)) }
                }
            }
        }
        #endif
        commandResults[command.id] = outcome
        return outcome
    }

    #if os(macOS)
    func receiveCommand(_ command: VoiceCommand, header: VoiceSignalHeader) {
        Task {
            let outcome: VoiceCommandResult.Outcome
            if case .repeatReply = command.action,
               remote?.header.session != header.session || remote?.header.sender != header.sender || remote?.header.recipient != header.recipient {
                outcome = .rejected(reason: .sourceMismatch)
            } else {
                outcome = await execute(command, mediaSession: header.session)
            }
            do {
                try await signaling?.sendVoice(.commandResult(result: .init(command: command.id, outcome: outcome)),
                                               session: header.session, to: header.sender)
            } catch { AppServices.log.error("Voice command result could not be delivered: \(String(describing: error))") }
        }
    }

    func execute(_ command: VoiceCommand, mediaSession: VoiceSessionID?) async -> VoiceCommandResult.Outcome {
        if let existing = commands[command.id] { return await existing.value }
        let operation = Task { await perform(command, mediaSession: mediaSession) }
        commands[command.id] = operation
        return await operation.value
    }

    private func perform(_ command: VoiceCommand, mediaSession: VoiceSessionID?) async -> VoiceCommandResult.Outcome {
        let services = services
        do {
            switch command.action {
            case .recover(let reference):
                let message: CueMessage
                switch reference {
                case .recorded(let original):
                    guard let row = try await services.store.cueMessages([original]).first else { return .rejected(reason: .originalMissing) }
                    guard row.deliveredAt == nil else { return .rejected(reason: .alreadyHandled) }
                    guard Said.cue(row, host: services.hostID).trip(at: services.speech).unconfirmedReason == nil else {
                        return .rejected(reason: .unconfirmed)
                    }
                    message = try await services.store.recoverCueMessage(original, host: services.hostID)
                case .unrecorded(let origin, let request):
                    guard let call, let row = call.requests.first(where: { $0.rowID == request && $0.origin == origin }),
                          row.message == nil, row.failure != nil, call.writing[row.id] == nil else { return .rejected(reason: .originalMissing) }
                    guard let index = call.requestState.firstIndex(where: { $0.rowID == request }) else { return .rejected(reason: .originalMissing) }
                    call.requestState[index].submission = .recording
                    do {
                        let id = try await services.recordVoiceSpeech(row.text, command: command.id.rawValue)
                        guard let recorded = try await services.store.cueMessages([id]).first else { throw CueStoreError.notFound }
                        message = recorded
                    } catch {
                        call.requestState[index].submission = row.submission
                        throw error
                    }
                    if let index = call.requestState.firstIndex(where: { $0.rowID == request }) {
                        call.requestState[index].submission = .recorded(message.id)
                        call.watchRequests()
                    }
                }
                Task { await services.upload(message.id) }
                if let call, case .recorded(let original) = reference,
                   let index = call.requestState.firstIndex(where: { $0.message == original }) {
                    call.requestState[index].submission = .recorded(message.id)
                    call.watchRequests()
                }
                return .recorded(message: message.id)
            case .repeatReply(let id):
                guard let call, VoiceSessionID(call.session) == mediaSession, call.canRepeat, let index = call.replyState.firstIndex(where: { $0.id == id }),
                      let original = try await services.store.cueMessages([id]).first, original.author == .known(.cue) else {
                    return .rejected(reason: .originalMissing)
                }
                guard VoiceSessionID(call.session) == mediaSession, call.canRepeat, call.replyState[index].delivery != .sending, call.replyState[index].delivery != .queued else {
                    return .rejected(reason: .unavailable)
                }
                let reply = VoiceCall.Reply(message: original, delivery: call.replyState[index].delivery)
                guard !reply.text.isEmpty else { return .rejected(reason: .originalMissing) }
                call.replyState[index] = reply
                call.repeatReply(id)
                return .readbackQueued(message: id)
            case .stop(let target):
                guard services.pi.session(sessionID: target.turn.sessionID)?.turnStartedAt?.stored == target.turn.turnStartedAtMilliseconds else {
                    return .rejected(reason: .turnChanged)
                }
                let stop = try await services.store.stopVoiceExecution(target.turn, requests: [target.request], command: command.id.rawValue)
                if let call, !call.stopRequests.contains(where: { $0.id == stop.id }) {
                    call.stopRequests.append(stop)
                    call.watchRequests()
                }
                _ = services.uploaded(stop)
                return .stopRequested(delivery: stop.id)
            }
        } catch CueStoreError.notFound { return .rejected(reason: .originalMissing) }
        catch CueStoreError.deliveryAlreadyHanded { return .rejected(reason: .alreadyHandled) }
        catch CueStoreError.cannotStop { return .rejected(reason: .turnChanged) }
        catch { return .rejected(reason: .failed) }
    }
    #endif
}
