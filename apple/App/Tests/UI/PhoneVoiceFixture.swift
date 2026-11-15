import CueStore
import Foundation
import Testing
@testable import CuePad

@MainActor final class VoiceGate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; let all = waiters; waiters = []; all.forEach { $0.resume() } }
}

@MainActor final class FakeVoiceMedia: VoiceMedia {
    var onEvent: (VoicePeer.Event) -> Void = { _ in }
    var offerGate: VoiceGate?
    var closeGate: VoiceGate?
    var offered = false
    var closing = false
    var closed = false
    func offer() async throws -> String { offered = true; await offerGate?.wait(); return "isolated-offer" }
    func accept(answer: String) async throws { onEvent(.connected) }
    func setMuted(_ value: Bool) async throws {}
    func close() async { closing = true; await closeGate?.wait(); closed = true }
}

@MainActor final class FakeVoiceSignaling: VoiceSignaling {
    let local = VoiceEndpoint(device: .init("phone-audit"), lease: UUID())
    var peer = VoiceEndpoint(device: .init("mac-audit"), lease: UUID())
    var voiceAvailability: VoiceRelayAvailability { .ready(endpoint: local) }
    var voiceEvents: AsyncStream<VoiceRelayEvent> { AsyncStream { _ in } }
    var sent: [VoiceSignalPayload] = []
    var recipients: [VoiceEndpoint] = []
    var failConnected = false
    /// 给了就让解析挂在它上面（中转连着却不回解析）
    var resolveGate: VoiceGate?
    func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint {
        await resolveGate?.wait()
        return peer
    }
    func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws {
        if failConnected, case .media(.event(.connected)) = payload { throw URLError(.networkConnectionLost) }
        sent.append(payload)
        recipients.append(recipient)
    }
    func event(_ payload: VoiceSignalPayload, session: VoiceSessionID) -> VoiceRelayEvent {
        .received(.init(header: .init(version: VoiceSignalFormat.version, sender: peer, recipient: local, session: session, sequence: 1, expiresAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1000) + 30000, purpose: payload.purpose), payload: payload))
    }
}

#if os(iOS)
/// 手机拨出并接通到"在听"；之后的入站信令由测试用 `voice.receive` 注入。
@MainActor func connectedPhone(makeMedia: @escaping () -> FakeVoiceMedia = { FakeVoiceMedia() }) async throws -> (TestApp, VoiceService, FakeVoiceSignaling, FakeVoiceMedia) {
    let app = TestApp(), signal = FakeVoiceSignaling()
    var media: FakeVoiceMedia?
    try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
    let voice = VoiceService(services: app.services, signaling: signal, makeMedia: {
        let next = makeMedia()
        media = next
        return next
    })
    app.services.voice = voice
    try await Workspace(services: app.services).startVoiceCall()
    let id = try #require(voice.session)
    await voice.receive(signal.event(.media(signal: .answer(value: .init(sdp: "isolated-answer"))), session: id))
    await voice.receive(signal.event(.projection(value: .init(session: id, phase: .listening, requests: [], replies: [])), session: id))
    return (app, voice, signal, try #require(media))
}
#endif
