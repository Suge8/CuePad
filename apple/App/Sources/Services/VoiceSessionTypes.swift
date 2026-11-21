import CueStore
import Foundation

nonisolated struct VoiceSessionID: Hashable, Codable, Sendable {
    let rawValue: UUID
    init(_ rawValue: UUID) { self.rawValue = rawValue }
}

nonisolated struct VoiceDeviceID: Hashable, Codable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

nonisolated struct VoiceEndpoint: Hashable, Codable, Sendable {
    let device: VoiceDeviceID
    let lease: UUID
}

nonisolated enum VoiceEndReason: String, Codable, Sendable {
    case hungUp, permissionDenied, audioInterrupted, mediaFailed, controlFailed
    case peerLeft, leaseReplaced, accountChanged, networkFailed, timedOut, protocolRejected, relayCapacity
}

nonisolated struct VoiceCallProjection: Equatable, Codable, Sendable {
    enum Phase: Equatable, Codable, Sendable {
        case connecting, listening, speaking, closing
        case failed(VoiceIssue)
        case ended(reason: VoiceEndReason)
    }
    let session: VoiceSessionID
    let phase: Phase
    let requests: [Request]
    let replies: [Reply]
    enum Response: String, Codable, Sendable { case none, awaitingAssistant, assistantTurn }
    var response: Response = .none
    var omitted = Omitted()
    var canRepeat = false

    struct Omitted: Equatable, Codable, Sendable {
        var requests = 0
        var replies = 0
    }

    struct Request: Equatable, Codable, Sendable {
        var id = UUID()
        let reference: VoiceRequestReference
        let recording: Bool
        let issue: VoiceIssue?
        var preview: RequestPreview? = nil
    }
    struct RequestPreview: Equatable, Codable, Sendable {
        let text: String
        let truncated: Bool
    }
    struct Reply: Equatable, Codable, Sendable {
        let message: UUID
        let readback: Readback
    }
    enum Readback: String, Codable, Sendable { case awaitingOrigin, queued, sending, submitted, unconfirmed }
}

nonisolated enum VoiceIssue: Error, Equatable, Codable, Sendable {
    case ended(VoiceEndReason)
    case codexNotInstalled, signedOut, codexUnresponsive, cueUnavailable, macUnavailable, relayUnsupported, busy
    case notAllowed(status: Int)
    case server(status: Int?)
    case storageUnavailable
}
