#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 手机通话对迟到、作废、失败的信令：只有属于这一通、这一条命令的才动它。替身见 `PhoneVoiceFixture`。
@Suite(.releasesLibraries, .serialized) @MainActor struct PhoneVoiceCallTests {
    @Test func cancelledCommandLateAckMustNotHangUp() async throws {
        let (app, voice, signal, media) = try await connectedPhone()
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services), session = try #require(voice.session)
        let task = Task { try await workspace.performVoice(.recover(.recorded(message: UUID()))) }
        try await eventually("command submitted") { signal.sent.contains { if case .command = $0 { true } else { false } } }
        task.cancel(); _ = await task.result
        let command = try #require(signal.sent.lazy.compactMap { if case .command(let command) = $0 { command.id } else { nil } }.first)
        await voice.receive(signal.event(.commandResult(result: .init(command: command, outcome: .recorded(message: UUID()))), session: session))
        #expect(!media.closed, "Late business ack after caller cancellation must not close media")
        #expect(workspace.voiceViewState.phase == .listening)
        try await workspace.performVoice(.hangUp)
    }

    @Test func commandRejectionSettlesOnlyItsCommandDuringCurrentMedia() async throws {
        let (app, voice, signal, media) = try await connectedPhone()
        defer { app.services.cancelBackgroundWork() }
        let firstID = UUID(), secondID = UUID(), session = try #require(voice.session)
        let first = Task { try await voice.command(.recover(request: .recorded(message: UUID())), id: firstID) }
        let second = Task { try await voice.command(.recover(request: .recorded(message: UUID())), id: secondID) }
        try await eventually("both commands sent") { signal.sent.filter { if case .command = $0 { true } else { false } }.count == 2 }
        let header = VoiceSignalHeader(version: VoiceSignalFormat.version, sender: signal.local, recipient: signal.peer, session: session,
                                       sequence: 1, expiresAtMilliseconds: 1, purpose: .command(id: .init(firstID)))
        await voice.receive(.rejected(header: header, reason: .unavailable))
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
        let app = TestApp(), signal = FakeVoiceSignaling(), media = FakeVoiceMedia()
        defer { app.services.cancelBackgroundWork() }
        try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
        let voice = VoiceService(services: app.services, signaling: signal, makeMedia: { media })
        app.services.voice = voice
        let workspace = Workspace(services: app.services)
        try await workspace.startVoiceCall()
        signal.failConnected = true
        let session = try #require(voice.session)
        await voice.receive(signal.event(.media(signal: .answer(value: .init(sdp: "isolated-answer"))), session: session))
        try await eventually("failed connected send cleanup completed") { workspace.voiceViewState.phase == .ended(reason: .networkFailed) }
        #expect(media.closed)
        #expect(signal.sent.contains { if case .media(.hangup(reason: .networkFailed)) = $0 { true } else { false } })
    }

    /// 上一通的拒收包、投影与媒体回调都到不了新的一通。
    @Test func oldSessionSignalsCannotTouchTheNewCall() async throws {
        var nextMedia = FakeVoiceMedia()
        let (app, voice, signal, media) = try await connectedPhone(makeMedia: { nextMedia })
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let old = try #require(voice.session), callback = media.onEvent
        let header = VoiceSignalHeader(version: VoiceSignalFormat.version, sender: signal.local, recipient: signal.peer, session: old, sequence: 1, expiresAtMilliseconds: 1, purpose: .media)
        try await workspace.performVoice(.hangUp)
        let next = FakeVoiceMedia()
        nextMedia = next
        try await workspace.startVoiceCall()
        await voice.receive(.rejected(header: header, reason: .unavailable))
        callback(.ended(.mediaFailed))
        await voice.receive(signal.event(.projection(value: .init(session: old, phase: .failed(.storageUnavailable), requests: [], replies: [], executions: [])), session: old))
        #expect(!next.closed, "Signals for the ended call must not terminate the new one")
        #expect(workspace.voiceViewState.phase == .connecting)
        try await workspace.performVoice(.hangUp)
    }

    @Test func connectionTimeoutMustNotifyPeerWithRealReason() async throws {
        let app = TestApp(), signal = FakeVoiceSignaling(), media = FakeVoiceMedia()
        defer { app.services.cancelBackgroundWork() }
        try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
        app.services.voice = VoiceService(services: app.services, signaling: signal, makeMedia: { media })
        let workspace = Workspace(services: app.services)
        try await workspace.startVoiceCall()
        try await eventually("real connection deadline") { workspace.voiceViewState.phase == .ended(reason: .timedOut) }
        #expect(media.closed)
        #expect(signal.sent.contains { if case .media(.hangup(reason: .timedOut)) = $0 { true } else { false } }, "Successful transport must receive the timeout hangup")
    }

    /// iPhone 进后台、锁屏不结束通话：媒体与 Mac 的信令都留着，之后照常挂断。
    @Test func backgroundKeepsTheCall() async throws {
        let (app, _, signal, media) = try await connectedPhone()
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        await app.services.prepareForBackground()
        #expect(!media.closing)
        #expect(workspace.voiceViewState.phase == .listening)
        #expect(!signal.sent.contains { if case .media(.hangup) = $0 { true } else { false } })
        try await workspace.performVoice(.hangUp)
        #expect(media.closed)
        #expect(workspace.voiceViewState.phase == .ended(reason: .hungUp))
        #expect(signal.sent.contains { if case .media(.hangup(reason: .hungUp)) = $0 { true } else { false } })
    }

    @Test func mediaEndDoesNotCancelPendingBusinessAndDisconnectDoesNotResend() async throws {
        let (app, voice, signal, _) = try await connectedPhone()
        defer { app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let session = try #require(voice.session), id = UUID(), message = UUID()
        let task = Task { try await voice.command(.recover(request: .recorded(message: message)), id: id) }
        try await eventually("command submitted") { signal.sent.contains { if case .command = $0 { true } else { false } } }
        try await workspace.performVoice(.hangUp)
        await voice.receive(signal.event(.commandResult(result: .init(command: .init(id), outcome: .recorded(message: message))), session: session))
        #expect(try await task.value == .recorded(message: message))
        let next = Task { try await workspace.performVoice(.recover(.recorded(message: message))) }
        try await eventually("second command submitted") { signal.sent.filter { if case .command = $0 { true } else { false } }.count == 2 }
        await voice.receive(.localClosed(endpoint: signal.local, reason: .networkFailed))
        if case .success = await next.result { Issue.record("Disconnected command unexpectedly confirmed") }
        #expect(signal.sent.filter { if case .command = $0 { true } else { false } }.count == 2)
    }
}
#endif
