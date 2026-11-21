import Foundation

nonisolated enum VoiceSignalPayload: Equatable, Codable, Sendable {
    case media(signal: VoiceMediaSignal)
    case command(command: VoiceCommand)
    case commandResult(result: VoiceCommandResult)
    case projection(value: VoiceCallProjection)
    case live(signal: LiveSignal)
}

nonisolated enum VoiceSignalPurpose: Equatable, Codable, Sendable {
    case media
    case command(id: VoiceCommand.ID)
    case commandResult(id: VoiceCommand.ID)
}

extension VoiceSignalPayload {
    var purpose: VoiceSignalPurpose {
        switch self {
        case .media, .projection: .media
        case .command(let command): .command(id: command.id)
        case .commandResult(let result): .commandResult(id: result.command)
        case .live(let signal): signal.answers ? .commandResult(id: .init(signal.request)) : .command(id: .init(signal.request))
        }
    }
}

nonisolated enum VoiceMediaSignal: Equatable, Codable, Sendable {
    case offer(value: VoiceOffer)
    case answer(value: VoiceAnswer)
    case event(value: VoiceMediaEvent)
    case hangup(reason: VoiceEndReason)
    case resume(ask: Bool)
}

nonisolated struct VoiceSignalHeader: Equatable, Codable, Sendable {
    let version: UInt8
    let sender: VoiceEndpoint
    let recipient: VoiceEndpoint
    let session: VoiceSessionID
    let sequence: UInt32
    let expiresAtMilliseconds: Int64
    let purpose: VoiceSignalPurpose

    func authenticationData() throws -> Data { try VoiceSignalFormat.canonicalJSON(self) }
}

nonisolated struct VoiceSealedSignal: Equatable, Codable, Sendable {
    let header: VoiceSignalHeader
    let sealed: Data
}

nonisolated struct VoiceReceivedSignal: Equatable, Sendable {
    let header: VoiceSignalHeader
    let payload: VoiceSignalPayload
}

nonisolated enum VoiceSignalFormat {
    static let version: UInt8 = 1
    static let callVersion: UInt8 = 3
    static let maximumWireBytes = 64 * 1024
    static let maximumPlaintextBytes = 32 * 1024
    static let maximumDeviceIDBytes = 128
    static let replacedCloseCode = 4409
    static let lifetimeMilliseconds: Int64 = 30_000
    static let clockSkewMilliseconds: Int64 = 60_000
    static let keyContext = "cuepad-voice-signal-v1"
    static let registrationContext = "cuepad-relay-voice-v1"

    static func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
