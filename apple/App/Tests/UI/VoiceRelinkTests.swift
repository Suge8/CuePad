import CueStore
import Foundation
import Testing
@testable import CuePad

/// 中转断开时通话照常，对端在宽限期内以新租约回来就接着打（`VoiceLink`）；替身见 `Voice89AuditTests`。
@Suite(.serialized) @MainActor struct VoiceRelinkTests {
    #if os(iOS)
    /// 中转断了不挂电话：Mac 以新租约回来的那帧带着最新投影，手机换绑、回 resume，之后的挂断送到新租约。
    @Test func relayDropKeepsTheCallUntilTheMacComesBack() async throws {
        let (app, voice, signal, media) = try await Voice89AuditTests().phone()
        defer { app.services.cancelBackgroundWork() }
        let session = try #require(voice.session), old = signal.peer
        await voice.receive(.peerClosed(endpoint: old, reason: .disconnected))
        #expect(!media.closing)
        #expect(voice.isLive)
        signal.peer = VoiceEndpoint(device: old.device, lease: UUID())
        await voice.receive(signal.event(.projection(value: .init(session: session, phase: .speaking, requests: [], replies: [], executions: [])), session: session))
        #expect(voice.phase == .speaking)
        try await eventually("resume to the new lease") {
            signal.sent.last == .media(signal: .resume) && signal.recipients.last == signal.peer
        }
        await Workspace(services: app.services).hangUpVoiceCall()
        #expect(voice.phase == .ended(reason: .hungUp))
        #expect(signal.sent.last == .media(signal: .hangup(reason: .hungUp)) && signal.recipients.last == signal.peer)
    }

    /// 中转连着却一直不回解析：通话仍在宽限期满时按断开的原因结束，不被这次解析拖住。
    @Test func aStuckLookupCannotOutlastTheGrace() async throws {
        let (app, voice, signal, media) = try await Voice89AuditTests().phone()
        defer { app.services.cancelBackgroundWork() }
        signal.resolveGate = AuditGate()
        let began = ContinuousClock.now
        await voice.receive(.peerClosed(endpoint: signal.peer, reason: .disconnected))
        try await eventually("grace expired") { voice.phase == .ended(reason: .peerLeft) }
        let waited = ContinuousClock.now - began
        #expect(waited >= VoiceSignalFormat.relinkGrace && waited < VoiceSignalFormat.relinkGrace + .seconds(2), "ended after \(waited)")
        #expect(media.closed)
        signal.resolveGate?.open()
    }
    #endif

    #if os(macOS)
    /// 手机换绑期间先到的一条"再说一遍"：Mac 认它是手机回来了，照常执行，不因来源不符拒绝。
    @Test func aCommandFromThePhonesNewLeaseRelinksAndRuns() async throws {
        let app = TestApp(), store = app.services.store, signal = AuditSignaling(), host = TestApp.hostID
        defer { app.services.cancelBackgroundWork() }
        try await store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        let voice = VoiceService(services: app.services, signaling: signal)
        app.services.voice = voice
        let fixture = VoiceFlowFixture(app.services)
        try await fixture.connect()
        let reply = try await store.addCueMessage(.cue, text: "saved result", answeredRequests: nil)
        try await eventually("reply visible") { fixture.call.canRepeat && fixture.call.replies.contains { $0.id == reply.id } }
        let session = VoiceSessionID(fixture.call.session), phone = VoiceDeviceID("phone-audit")
        let gone = VoiceEndpoint(device: phone, lease: UUID()), back = VoiceEndpoint(device: phone, lease: UUID())
        let remote = VoiceRemoteMedia(header: .init(version: 1, sender: gone, recipient: signal.local, session: session, sequence: 1,
                                                    expiresAtMilliseconds: 0, purpose: .media), offer: .init(sdp: "offer"), signaling: signal)
        remote.link = .relinking(peer: phone, until: .now + VoiceSignalFormat.relinkGrace, reason: .peerLeft)
        voice.remote = remote
        let id = VoiceCommand.ID(UUID())
        let command = VoiceCommand(id: id, action: .repeatReply(message: reply.id))
        await voice.receive(.received(.init(header: .init(version: 1, sender: back, recipient: signal.local, session: session, sequence: 1,
                                                          expiresAtMilliseconds: .max, purpose: .command(id: id)),
                                            payload: .command(command: command))))
        #expect(remote.link == .bound(local: signal.local, peer: back))
        try await eventually("result sent") { signal.sent.contains { if case .commandResult = $0 { true } else { false } } }
        #expect(signal.sent.last == .commandResult(result: .init(command: id, outcome: .readbackQueued(message: reply.id))))
        #expect(signal.recipients.last == back)
        voice.remote = nil
        try await fixture.hangUp()
    }
    #endif
}
