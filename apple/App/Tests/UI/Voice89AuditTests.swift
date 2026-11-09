import CryptoKit
import CueStore
#if os(macOS)
import CuePi
#endif
import Foundation
import Testing
@testable import CuePad

@MainActor final class AuditGate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
    func open() { opened = true; let all = waiters; waiters = []; all.forEach { $0.resume() } }
}

@MainActor final class AuditMedia: VoiceMedia {
    var onEvent: (VoicePeer.Event) -> Void = { _ in }
    var offerGate: AuditGate?
    var closeGate: AuditGate?
    var offered = false
    var closing = false
    var closed = false
    func offer() async throws -> String { offered = true; await offerGate?.wait(); return "isolated-offer" }
    func accept(answer: String) async throws { onEvent(.connected) }
    func setMuted(_ value: Bool) async throws {}
    func close() async { closing = true; await closeGate?.wait(); closed = true }
}

@MainActor final class AuditSignaling: VoiceSignaling {
    let local = VoiceEndpoint(device: .init("phone-audit"), lease: UUID())
    var peer = VoiceEndpoint(device: .init("mac-audit"), lease: UUID())
    var voiceAvailability: VoiceRelayAvailability { .ready(endpoint: local) }
    var voiceEvents: AsyncStream<VoiceRelayEvent> { AsyncStream { _ in } }
    var sent: [VoiceSignalPayload] = []
    var recipients: [VoiceEndpoint] = []
    var failConnected = false
    /// 给了就让解析挂在它上面（中转连着却不回解析）
    var resolveGate: AuditGate?
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
        .received(.init(header: .init(version: 1, sender: peer, recipient: local, session: session, sequence: 1, expiresAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1000) + 30000, purpose: payload.purpose), payload: payload))
    }
}

@Suite(.serialized) @MainActor struct Voice89AuditTests {
    @Test func signedLeaseReplayAndOldCallback() async throws {
        let key = SymmetricKey(size: .bits256)
        let a = VoiceSignalConnection(room: "isolated", challenge: "same", device: .init("a"), key: key)
        let a2 = VoiceSignalConnection(room: "isolated", challenge: "same", device: .init("a"), key: key)
        let b = VoiceSignalConnection(room: "isolated", challenge: "same", device: .init("b"), key: key)
        #expect(a.claim.endpoint != a2.claim.endpoint)
        for c in [a, a2, b] { try c.acceptRegistration(c.claim.endpoint) }
        try a.bind(b.claim.endpoint); try a2.bind(b.claim.endpoint); try b.bind(a.claim.endpoint)
        let session = VoiceSessionID(UUID())
        let old = try a.seal(.media(signal: .hangup(reason: .hungUp)), session: session, to: b.claim.endpoint, now: 1000)
        _ = try b.open(old, now: 1001)
        #expect(throws: (any Error).self) { try b.open(old, now: 1001) }
        try b.bind(a2.claim.endpoint)
        #expect(throws: (any Error).self) { try b.open(old, now: 1001) }
        let fresh = try a2.seal(.media(signal: .hangup(reason: .hungUp)), session: VoiceSessionID(UUID()), to: b.claim.endpoint, now: 1001)
        _ = try b.open(fresh, now: 1002)
        try b.retire(a.claim.endpoint)
        let next = try a2.seal(.media(signal: .hangup(reason: .hungUp)), session: session, to: b.claim.endpoint, now: 1002)
        _ = try b.open(next, now: 1003)
    }

    #if os(macOS)
    @Test func commandsRetainOriginalIdentityAcrossMediaClose() async throws {
        let app = TestApp(), store = app.services.store, host = TestApp.hostID
        defer { app.services.cancelBackgroundWork() }
        try await store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        let fixture = VoiceFlowFixture(app.services)
        try await fixture.connect()
        let original = try await store.addCueMessage(.you, text: "original audit request")
        let result = try await store.addCueMessage(.cue, text: "saved result", answeredRequests: nil)
        try await eventually("saved result visible") { fixture.call.replies.contains { $0.id == result.id } }
        let command = UUID()
        let recovered = try await app.services.voice.command(.recover(request: .recorded(message: original.id)), id: command)
        #expect(recovered == .recorded(message: original.id))
        let gate = AsyncStream<Void>.makeStream()
        fixture.media.closeGate = gate.stream
        fixture.call.hangUp()
        try await eventually("closing") { fixture.call.phase == .closing }
        let outcome = try await app.services.voice.command(.repeatReply(message: result.id))
        if case .readbackQueued = outcome { Issue.record("Closing media must not accept readback") }
        let duringClose = try await app.services.voice.command(.recover(request: .recorded(message: original.id)), id: command)
        #expect(duringClose == recovered)
        gate.continuation.finish()
        try await eventually("closed") { !fixture.call.isLive }
        try await store.markCueMessagesDelivered([original.id])
        #expect(try await app.services.voice.command(.recover(request: .recorded(message: original.id))) == .rejected(reason: .alreadyHandled))
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.map(\.id) == [original.id])
        #expect(fixture.controls[0].sends.isEmpty)
    }
    #endif

    #if os(iOS)
    func phone(makeMedia: @escaping () -> AuditMedia = { AuditMedia() }) async throws -> (TestApp, VoiceService, AuditSignaling, AuditMedia) {
        let app = TestApp(), signal = AuditSignaling()
        var media: AuditMedia?
        try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
        let voice = VoiceService(services: app.services, signaling: signal, makeMedia: {
            let next = makeMedia()
            media = next
            return next
        })
        app.services.voice = voice
        try await voice.start()
        let id = try #require(voice.session)
        await voice.receive(signal.event(.media(signal: .answer(value: .init(sdp: "isolated-answer"))), session: id))
        await voice.receive(signal.event(.projection(value: .init(session: id, phase: .listening, requests: [], replies: [], executions: [])), session: id))
        return (app, voice, signal, try #require(media))
    }

    @Test func cancelledCommandLateAckMustNotHangUp() async throws {
        let (app, voice, signal, media) = try await phone()
        defer { app.services.cancelBackgroundWork() }
        let id = UUID(), session = try #require(voice.session)
        let task = Task { try await voice.command(.recover(request: .recorded(message: UUID())), id: id) }
        try await eventually("command submitted") { signal.sent.contains { if case .command = $0 { true } else { false } } }
        task.cancel(); _ = await task.result
        #expect(voice.pending.isEmpty)
        await voice.receive(signal.event(.commandResult(result: .init(command: .init(id), outcome: .recorded(message: UUID()))), session: session))
        #expect(!media.closed, "Late business ack after caller cancellation must not close media")
        #expect(voice.phase == .listening)
        await voice.end(notify: false)
    }

    @Test func commandRejectionSettlesOnlyItsCommandDuringCurrentMedia() async throws {
        let (app, voice, signal, media) = try await phone()
        defer { app.services.cancelBackgroundWork() }
        let firstID = UUID(), secondID = UUID(), session = try #require(voice.session)
        let first = Task { try await voice.command(.recover(request: .recorded(message: UUID())), id: firstID) }
        let second = Task { try await voice.command(.recover(request: .recorded(message: UUID())), id: secondID) }
        try await eventually("both commands sent") { signal.sent.filter { if case .command = $0 { true } else { false } }.count == 2 }
        let header = VoiceSignalHeader(version: 1, sender: signal.local, recipient: signal.peer, session: session,
                                       sequence: 1, expiresAtMilliseconds: 1, purpose: .command(id: .init(firstID)))
        await voice.receive(.rejected(header: header, reason: .unavailable))
        #expect(voice.pending[.init(firstID)] == nil)
        #expect(voice.pending[.init(secondID)] != nil)
        if case .failure(let error) = await first.result {
            if case VoiceSignalError.rejected(.unavailable) = error {} else { Issue.record("Wrong rejection reason: \(error)") }
        } else { Issue.record("Rejected command must fail immediately") }
        #expect(!media.closed)
        #expect(voice.phase == .listening)
        await voice.receive(signal.event(.commandResult(result: .init(command: .init(secondID), outcome: .recorded(message: UUID()))), session: session))
        _ = try await second.value
        await voice.end(notify: false)
    }

    @Test func scopeOwnedConnectedFailureStillSendsHangup() async throws {
        let app = TestApp(), signal = AuditSignaling(), media = AuditMedia()
        defer { app.services.cancelBackgroundWork() }
        try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
        let voice = VoiceService(services: app.services, signaling: signal, makeMedia: { media })
        app.services.voice = voice
        try await voice.start()
        signal.failConnected = true
        let session = try #require(voice.session)
        await voice.receive(signal.event(.media(signal: .answer(value: .init(sdp: "isolated-answer"))), session: session))
        try await eventually("failed connected send cleanup completed") { voice.phone == nil }
        #expect(media.closed)
        #expect(signal.sent.contains { if case .media(.hangup(reason: .networkFailed)) = $0 { true } else { false } })
        #expect(voice.phase == .ended(reason: .networkFailed))
    }

    @Test func oldRejectedPacketMustNotCloseNewMediaSession() async throws {
        var nextMedia = AuditMedia()
        let (app, voice, signal, _) = try await phone(makeMedia: { nextMedia })
        defer { app.services.cancelBackgroundWork() }
        let old = try #require(voice.session)
        let header = VoiceSignalHeader(version: 1, sender: signal.local, recipient: signal.peer, session: old, sequence: 1, expiresAtMilliseconds: 1, purpose: .media)
        await voice.end(notify: false)
        let next = AuditMedia()
        nextMedia = next
        try await voice.start()
        #expect(voice.session != old)
        await voice.receive(.rejected(header: header, reason: .unavailable))
        #expect(!next.closed, "A rejected packet for the ended session must not terminate the new session")
        #expect(voice.phase == .connecting)
        await voice.end(notify: false)
    }

    @Test func connectionTimeoutMustNotifyPeerWithRealReason() async throws {
        let app = TestApp(), signal = AuditSignaling(), media = AuditMedia()
        defer { app.services.cancelBackgroundWork() }
        try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
        let voice = VoiceService(services: app.services, signaling: signal, makeMedia: { media }); app.services.voice = voice
        try await voice.start()
        try await eventually("real connection deadline") { media.closed && voice.phone == nil }
        #expect(signal.sent.contains { if case .media(.hangup(reason: .timedOut)) = $0 { true } else { false } }, "Successful transport must receive the timeout hangup")
        #expect(voice.phase == .ended(reason: .timedOut), "Self cancellation must not invent networkFailed")
    }

    @Test func closingExclusiveAndOldCallbacksCannotCloseNew() async throws {
        var nextMedia = AuditMedia()
        let (app, voice, signal, media) = try await phone(makeMedia: { nextMedia })
        defer { app.services.cancelBackgroundWork() }
        let old = try #require(voice.session), callback = media.onEvent, gate = AuditGate()
        media.closeGate = gate
        let end = Task { await voice.end(notify: false) }
        try await eventually("closing") { media.closing }
        #expect(!voice.canStart)
        await #expect(throws: VoiceIssue.busy) { try await voice.start() }
        gate.open(); await end.value
        let next = AuditMedia(); nextMedia = next; try await voice.start()
        let current = try #require(voice.session)
        #expect(old != current)
        callback(.ended(.mediaFailed))
        await voice.receive(signal.event(.projection(value: .init(session: old, phase: .failed(.storageUnavailable), requests: [], replies: [], executions: [])), session: old))
        #expect(!next.closed); #expect(voice.session == current)
        await voice.end(notify: false)
    }

    /// iPhone 进后台、锁屏不结束通话：媒体与 Mac 的信令都留着，之后照常挂断。
    @Test func backgroundKeepsTheCall() async throws {
        let (app, voice, signal, media) = try await phone()
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        await app.services.prepareForBackground()
        #expect(!media.closing)
        #expect(voice.isLive)
        #expect(!signal.sent.contains { if case .media(.hangup) = $0 { true } else { false } })
        await workspace.hangUpVoiceCall()
        #expect(media.closed)
        #expect(workspace.phoneVoice.phase == .ended(reason: .hungUp))
        #expect(signal.sent.contains { if case .media(.hangup(reason: .hungUp)) = $0 { true } else { false } })
    }

    @Test func mediaEndDoesNotCancelPendingBusinessAndDisconnectDoesNotResend() async throws {
        let (app, voice, signal, _) = try await phone()
        defer { app.services.cancelBackgroundWork() }
        let session = try #require(voice.session), id = UUID(), message = UUID()
        let task = Task { try await voice.command(.recover(request: .recorded(message: message)), id: id) }
        try await eventually("command pending") { !voice.pending.isEmpty }
        await voice.end(notify: false)
        #expect(!voice.pending.isEmpty)
        await voice.receive(signal.event(.commandResult(result: .init(command: .init(id), outcome: .recorded(message: message))), session: session))
        #expect(try await task.value == .recorded(message: message))
        let next = Task { try await voice.command(.recover(request: .recorded(message: message))) }
        try await eventually("second command submitted") { signal.sent.filter { if case .command = $0 { true } else { false } }.count == 2 }
        await voice.receive(.localClosed(endpoint: signal.local, reason: .networkFailed))
        if case .success = await next.result { Issue.record("Disconnected command unexpectedly confirmed") }
        #expect(signal.sent.filter { if case .command = $0 { true } else { false } }.count == 2)
    }
    #endif
}
