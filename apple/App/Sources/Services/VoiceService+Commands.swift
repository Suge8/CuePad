import CueStore
import Foundation
import os

extension VoiceService {
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
        let fromCall = remote?.leg.session == header.session && remote?.leg.link == .bound(local: header.recipient, peer: header.sender)
        Task {
            let outcome: VoiceCommandResult.Outcome
            if case .repeatReply = command.action, !fromCall {
                outcome = .rejected(reason: .sourceMismatch)
            } else {
                outcome = await execute(command, mediaSession: header.session)
            }
            var target: VoiceEndpoint? = header.sender
            if let remote, remote.leg.session == header.session {
                remote.results[command.id] = outcome
                if case .bound(_, let phone)? = remote.leg.link { target = phone } else { target = nil }
            }
            guard let target else { return }
            await sendResult(.init(command: command.id, outcome: outcome), session: header.session, to: target)
        }
    }

    func sendResult(_ result: VoiceCommandResult, session: VoiceSessionID, to phone: VoiceEndpoint) async {
        do { try await signaling?.sendVoice(.commandResult(result: result), session: session, to: phone) }
        catch { AppServices.log.error("Voice command result could not be delivered: \(String(describing: error))") }
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
            case .recover(.recorded(let original)):
                guard let row = try await services.store.cueMessages([original]).first else { return .rejected(reason: .originalMissing) }
                guard row.deliveredAt == nil else { return .rejected(reason: .alreadyHandled) }
                guard Said.cue(row, host: services.hostID).trip(at: services.speech).unconfirmedReason == nil else {
                    return .rejected(reason: .unconfirmed)
                }
                let message = try await services.store.recoverCueMessage(original, host: services.hostID)
                call?.record.recovered(message.id)
                return .recorded(message: message.id)
            case .recover(.unrecorded(let origin, let request)):
                guard let id = try await call?.record.retry(request, origin: origin, command: command.id.rawValue) else {
                    return .rejected(reason: .originalMissing)
                }
                return .recorded(message: id)
            case .repeatReply(let id):
                guard let call, let mediaSession else { return .rejected(reason: .originalMissing) }
                return try call.repeatReply(id, mediaSession: mediaSession)
            }
        } catch CueStoreError.notFound { return .rejected(reason: .originalMissing) }
        catch CueStoreError.deliveryAlreadyHanded { return .rejected(reason: .alreadyHandled) }
        catch { return .rejected(reason: .failed) }
    }
    #endif
}
