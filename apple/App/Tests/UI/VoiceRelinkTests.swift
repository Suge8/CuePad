import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries, .serialized) @MainActor struct VoiceRelinkTests {
    #if os(iOS)
    @Test func relayDropKeepsTheCallUntilTheMacComesBack() async throws {
        let (app, voice, signal, media) = try await connectedPhone()
        let session = try #require(voice.session), old = signal.peer
        await voice.receive(.peerClosed(endpoint: old, reason: .disconnected))
        #expect(!media.closing)
        #expect(voice.isLive)
        signal.peer = VoiceEndpoint(device: old.device, lease: UUID())
        await voice.receive(signal.event(.projection(value: .init(session: session, phase: .speaking, requests: [], replies: [])), session: session))
        #expect(voice.phase == .speaking)
        #expect(voice.phone?.leg.link == .bound(local: signal.local, peer: signal.peer))
        await voice.receive(signal.event(.media(signal: .resume(ask: true)), session: session))
        try await eventually("answer to the new lease") {
            signal.sent.last == .media(signal: .resume(ask: false)) && signal.recipients.last == signal.peer
        }
        try await Workspace(services: app.services).performVoice(.hangUp)
        #expect(voice.phase == .ended(reason: .hungUp))
        #expect(signal.sent.last == .media(signal: .hangup(reason: .hungUp)) && signal.recipients.last == signal.peer)
    }

    @Test func codexNotRespondingOnTheMacEndsWithItsOwnReason() async throws {
        let (app, voice, signal, media) = try await connectedPhone()
        let session = try #require(voice.session), workspace = Workspace(services: app.services)
        await voice.receive(signal.event(.projection(value: .init(session: session, phase: .failed(.codexUnresponsive), requests: [], replies: [])), session: session))
        #expect(media.closed)
        #expect(workspace.phoneVoiceEnding == .failed(.codexUnresponsive))
        #expect(String(localized: VoiceIssue.codexUnresponsive.message) == "Codex 没响应，看看 Mac 上的提示")
        guard case .start? = VoiceIssue.codexUnresponsive.recovery else { Issue.record("没有重新接通"); return }
    }

    @Test func aStuckLookupCannotOutlastTheGrace() async throws {
        let (app, voice, signal, media) = try await connectedPhone()
        defer { withExtendedLifetime(app) {} }
        signal.resolveGate = VoiceGate()
        let began = ContinuousClock.now
        await voice.receive(.peerClosed(endpoint: signal.peer, reason: .disconnected))
        try await eventually("grace expired") { voice.phase == .ended(reason: .peerLeft) }
        let waited = ContinuousClock.now - began
        #expect(waited >= VoiceTiming.relinkGrace && waited < VoiceTiming.relinkGrace + .seconds(2), "ended after \(waited)")
        #expect(media.closed)
        signal.resolveGate?.open()
    }

    @Test func aCommandWaitsAcrossTheRelinkForItsResult() async throws {
        let (app, voice, signal, _) = try await connectedPhone()
        defer { withExtendedLifetime(app) {} }
        let session = try #require(voice.session), message = UUID(), id = UUID()
        let task = Task { try await voice.command(.recover(request: .recorded(message: message)), id: id) }
        try await eventually("command sent") { !voice.pending.isEmpty }
        await voice.receive(.localClosed(endpoint: signal.local, reason: .networkFailed))
        #expect(!voice.pending.isEmpty)
        signal.peer = VoiceEndpoint(device: signal.peer.device, lease: UUID())
        await voice.receive(signal.event(.media(signal: .resume(ask: false)), session: session))
        await voice.receive(signal.event(.commandResult(result: .init(command: .init(id), outcome: .recorded(message: message))), session: session))
        #expect(try await task.value == .recorded(message: message))
        #expect(signal.sent.filter { if case .command = $0 { true } else { false } }.count == 1)
        await voice.end(notify: false)
    }
    #endif

    #if os(macOS)
    @Test func aCommandBeforeResumeStillBringsProjectionsBack() async throws {
        let (app, signal, fixture) = try await answeredPhone()
        let store = app.services.store, voice = app.services.voice
        let first = try await store.addCueMessage(.cue, text: "first result", answeredRequests: nil)
        try await eventually("reply visible") { fixture.voiceRecord.replies.contains { $0.id == first.id } }
        let session = VoiceSessionID(fixture.call.session), gone = signal.peer
        await voice.receive(.peerClosed(endpoint: gone, reason: .disconnected))
        signal.peer = VoiceEndpoint(device: gone.device, lease: UUID())
        let back = signal.peer, id = VoiceCommand.ID(UUID())
        await voice.receive(signal.event(.command(command: .init(id: id, action: .repeatReply(message: first.id))), session: session))
        let result = VoiceSignalPayload.commandResult(result: .init(command: id, outcome: .readbackQueued(message: first.id)))
        try await eventually("the result reaches the new lease") { zip(signal.sent, signal.recipients).contains { $0 == result && $1 == back } }
        let later = try await store.addCueMessage(.cue, text: "later result", answeredRequests: nil)
        try await eventually("the later projection reaches the new lease") {
            zip(signal.sent, signal.recipients).contains {
                if case .projection(let value) = $0, value.replies.contains(where: { $0.message == later.id }) { $1 == back } else { false }
            }
        }
        try await fixture.hangUp()
    }

    @Test func aResultMadeWhileThePhoneIsAwayFollowsItToTheNewLease() async throws {
        let (app, signal, fixture) = try await answeredPhone()
        let store = app.services.store, voice = app.services.voice
        let reply = try await store.addCueMessage(.cue, text: "saved result", answeredRequests: nil)
        try await eventually("reply visible") { fixture.voiceRecord.replies.contains { $0.id == reply.id } }
        let session = VoiceSessionID(fixture.call.session), gone = signal.peer, id = VoiceCommand.ID(UUID())
        await voice.receive(signal.event(.command(command: .init(id: id, action: .repeatReply(message: reply.id))), session: session))
        await voice.receive(.peerClosed(endpoint: gone, reason: .disconnected))
        try await eventually("executed") { fixture.controls[0].sends.count == 1 }
        let result = VoiceSignalPayload.commandResult(result: .init(command: id, outcome: .readbackQueued(message: reply.id)))
        #expect(!signal.sent.contains(result))
        signal.peer = VoiceEndpoint(device: gone.device, lease: UUID())
        let back = signal.peer
        await voice.receive(signal.event(.media(signal: .resume(ask: true)), session: session))
        try await eventually("result followed the phone") { zip(signal.sent, signal.recipients).contains { $0 == result && $1 == back } }
        #expect(signal.sent.filter { $0 == result }.count == 1)
        #expect(fixture.controls[0].sends.count == 1)
        try await fixture.hangUp()
    }

    private func answeredPhone() async throws -> (TestApp, FakeVoiceSignaling, VoiceFlowFixture) {
        let app = TestApp(), signal = FakeVoiceSignaling(), host = TestApp.hostID
        try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        app.services.voice = VoiceService(services: app.services, signaling: signal)
        let fixture = VoiceFlowFixture(app.services)
        try await fixture.answer(signal)
        return (app, signal, fixture)
    }
    #endif
}
