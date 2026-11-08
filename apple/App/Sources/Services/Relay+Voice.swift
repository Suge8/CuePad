import Foundation

/// 既有 Relay 的单条 socket 所拥有的语音收发；实例不跨重连复用，旧回调只会碰旧作用域。
final class RelayVoiceConnection {
    let crypto: VoiceSignalConnection
    private let socket: URLSessionWebSocketTask
    private let emit: (VoiceRelayEvent) -> Void
    private let scope = VoiceOperationScope()
    private var sending: Task<Void, Never>?
    private struct Lookup {
        let device: VoiceDeviceID
        let finish: @MainActor @Sendable (Result<VoiceEndpoint, Error>) -> Void
        let timeout: Task<Void, Never>?
    }
    private var lookups: [UUID: Lookup] = [:]
    private static let maximumLookups = 128

    init(socket: URLSessionWebSocketTask, credentials: RelayCredentials, challenge: String, device: VoiceDeviceID,
         emit: @escaping (VoiceRelayEvent) -> Void) {
        self.socket = socket
        self.emit = emit
        crypto = VoiceSignalConnection(room: credentials.room, challenge: challenge, device: device, key: credentials.voiceKey)
    }

    func register(_ credentials: RelayCredentials) async throws {
        try await write(.register(claim: crypto.claim, signature: credentials.signVoice(crypto.claim)))
    }

    func close(_ reason: VoiceEndReason) {
        guard !scope.ended else { return }
        scope.end()
        crypto.end()
        lookups.removeAll()
        emit(.localClosed(endpoint: crypto.claim.endpoint, reason: reason))
    }

    func resolve(_ device: VoiceDeviceID) async throws -> VoiceEndpoint {
        guard lookups.count < Self.maximumLookups else { throw VoiceSignalError.tooLarge }
        let id = UUID()
        defer { lookups.removeValue(forKey: id)?.timeout?.cancel() }
        return try await scope.wait { finish in
            let timeout = scope.spawn {
                do {
                    try await Task.sleep(for: Relay.handshakeLimit)
                    self.complete(id, .failure(VoiceSignalError.expired))
                } catch { }
            }
            lookups[id] = Lookup(device: device, finish: finish, timeout: timeout)
            scope.spawn {
                do { try await self.write(.resolve(request: id, device: device)) }
                catch { self.complete(id, .failure(error)) }
            }
        }
    }

    func send(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws {
        try Task.checkCancellation()
        let previous = sending
        let job = Task {
            await previous?.value
            try Task.checkCancellation()
            let packet = try crypto.seal(payload, session: session, to: recipient, now: Self.now)
            try await write(.signal(packet: packet))
        }
        sending = Task { _ = await job.result }
        defer { job.cancel() }
        try await scope.perform { try await job.value }
    }

    func receive(_ response: VoiceRelayResponse) throws {
        switch response {
        case .registered: throw VoiceSignalError.invalid
        case .resolved(let id, let endpoint):
            guard let lookup = lookups[id] else { return }
            guard lookup.device == endpoint.device else { throw VoiceSignalError.invalid }
            try crypto.bind(endpoint)
            complete(id, .success(endpoint))
        case .unavailable(let id, let device):
            guard let lookup = lookups[id] else { return }
            guard lookup.device == device else { throw VoiceSignalError.invalid }
            complete(id, .failure(VoiceSignalError.peerUnavailable))
        case .departed(let endpoint, let reason):
            try crypto.retire(endpoint)
            emit(.peerClosed(endpoint: endpoint, reason: reason))
        case .signal(let packet):
            guard packet.header.recipient == crypto.claim.endpoint else { throw VoiceSignalError.leaseChanged }
            try crypto.bind(packet.header.sender)
            emit(.received(try crypto.open(packet, now: Self.now)))
        case .rejected(let header, let reason):
            guard header.sender == crypto.claim.endpoint else { throw VoiceSignalError.leaseChanged }
            emit(.rejected(header: header, reason: reason))
        }
    }

    private func complete(_ id: UUID, _ result: Result<VoiceEndpoint, Error>) {
        guard let lookup = lookups.removeValue(forKey: id) else { return }
        lookup.timeout?.cancel()
        lookup.finish(result)
    }

    private func write(_ request: VoiceRelayRequest) async throws {
        let bytes = try VoiceSignalFormat.canonicalJSON(Envelope(body: request))
        guard bytes.count <= VoiceSignalFormat.maximumWireBytes else { throw VoiceSignalError.tooLarge }
        try await scope.perform { try await self.socket.send(.string(String(decoding: bytes, as: UTF8.self))) }
    }

    private struct Envelope: Encodable {
        let t = "voice"
        let body: VoiceRelayRequest
    }
    private static var now: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }
}

extension Relay: VoiceSignaling {
    func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint {
        guard let voiceConnection else { throw voiceAvailability == .unsupported ? VoiceSignalError.unsupported : .unavailable }
        return try await voiceConnection.resolve(device)
    }

    func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws {
        guard let voiceConnection else { throw VoiceSignalError.unavailable }
        try await voiceConnection.send(payload, session: session, to: recipient)
    }
}
