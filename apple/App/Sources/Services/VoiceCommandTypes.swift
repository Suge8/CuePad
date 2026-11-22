import CueStore
import Foundation

nonisolated enum VoiceRequestReference: Hashable, Codable, Sendable {
    case recorded(message: UUID)
    case unrecorded(session: VoiceSessionID, request: UUID)
}

nonisolated struct VoiceCommand: Equatable, Codable, Sendable {
    struct ID: Hashable, Codable, Sendable {
        let rawValue: UUID
        init(_ rawValue: UUID) { self.rawValue = rawValue }
    }

    enum Action: Equatable, Codable, Sendable {
        case recover(request: VoiceRequestReference)
        case repeatReply(message: UUID)
    }

    let id: ID
    let action: Action
}

nonisolated struct VoiceCommandResult: Equatable, Codable, Sendable {
    enum Outcome: Equatable, Codable, Sendable {
        case recorded(message: UUID)
        case readbackQueued(message: UUID)
        case rejected(reason: Rejection)
    }

    enum Rejection: String, Codable, Sendable {
        case originalMissing, alreadyHandled, unconfirmed, sourceMismatch, unavailable, failed
    }

    let command: VoiceCommand.ID
    let outcome: Outcome
}
