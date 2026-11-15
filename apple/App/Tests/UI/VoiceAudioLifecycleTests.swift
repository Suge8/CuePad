#if os(iOS)
import CueStore
import Testing
@testable import CuePad

/// #99：手机的按钮入口与隔离库；媒体、中转、远端及权限等待用替身。
@Suite(.releasesLibraries, .serialized) @MainActor struct VoiceAudioLifecycleTests {
    final class Media: VoiceMedia {
        var onEvent: (VoicePeer.Event) -> Void = { _ in }
        var offerGate: VoiceGate?
        var closeGate: VoiceGate?
        var failure: (any Error)?
        var offered = false
        var closed = false
        func offer() async throws -> String {
            offered = true
            await offerGate?.wait()
            if let failure { throw failure }
            return "isolated-offer"
        }
        func accept(answer: String) async throws { onEvent(.connected) }
        func setMuted(_ value: Bool) async throws {}
        func close() async { await closeGate?.wait(); closed = true }
    }

    final class Fixture {
        let app = TestApp()
        let signal = FakeVoiceSignaling()
        let workspace: Workspace
        let saved: CueMessage
        var voice: VoiceService { app.services.voice }
        init(makeMedia: @escaping () -> any VoiceMedia) async throws {
            try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
            app.services.voice = VoiceService(services: app.services, signaling: signal, makeMedia: makeMedia)
            workspace = Workspace(services: app.services)
            saved = try await app.services.store.addCueMessage(.cue, text: "Keep this reply after the call")
        }
        func checkLibrary() async throws {
            #expect(try await app.services.store.cueMessages().map(\.id) == [saved.id])
            #expect(try await app.services.store.deliveryRequests().isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func interruptionKeepsItsReasonAndClosingExcludesReconnect(whileStarting: Bool) async throws {
        let media = Media(), gate = VoiceGate(), closeGate = VoiceGate()
        var nextMedia: any VoiceMedia = media
        let fixture = try await Fixture(makeMedia: { nextMedia })
        defer { gate.open(); closeGate.open(); fixture.app.services.cancelBackgroundWork() }
        media.closeGate = closeGate
        if whileStarting { media.offerGate = gate; media.failure = CancellationError() }
        let start = Task { try await fixture.workspace.startVoiceCall() }
        try await eventually("手机正在开始") { media.offered }
        if !whileStarting {
            try await start.value
            let session = try #require(fixture.voice.session)
            await fixture.voice.receive(fixture.signal.event(.media(signal: .answer(value: .init(sdp: "answer"))), session: session))
        }
        let oldCallback = media.onEvent
        oldCallback(.ended(.audioInterrupted))
        #expect(fixture.workspace.voiceViewState.phase == .closing)
        await #expect(throws: VoiceIssue.busy) { try await fixture.workspace.startVoiceCall() }
        gate.open()
        _ = await start.result
        closeGate.open()
        try await eventually("中断清理完成") { fixture.voice.phone == nil }
        #expect(fixture.workspace.voiceViewState.phase == .ended(reason: .audioInterrupted))
        let ended = try #require(fixture.voice.session)
        await fixture.voice.receive(fixture.signal.event(.projection(value: .init(
            session: ended, phase: .failed(.ended(.mediaFailed)), requests: [], replies: [])), session: ended))
        #expect(fixture.workspace.voiceViewState.phase == .ended(reason: .audioInterrupted), "Mac 收到挂断后的回声不改本机先落定的原因")
        #expect(fixture.signal.sent.contains { if case .media(.hangup(reason: .audioInterrupted)) = $0 { true } else { false } })
        let next = Media()
        nextMedia = next
        try await fixture.workspace.startVoiceCall()
        oldCallback(.ended(.audioInterrupted))
        #expect(fixture.workspace.voiceViewState.phase == .connecting)
        #expect(!next.closed)
        try await fixture.workspace.performVoice(.hangUp)
        #expect(fixture.workspace.voiceViewState.phase == .ended(reason: .hungUp))
        try await fixture.checkLibrary()
    }

    @Test func deniedPermissionCanBeRetriedWithoutChangingTheLibrary() async throws {
        var denied = true
        let fixture = try await Fixture(makeMedia: {
            let media = Media()
            if denied { media.failure = VoicePeerError.microphoneDenied }
            return media
        })
        defer { fixture.app.services.cancelBackgroundWork() }
        for _ in 0..<2 {
            await #expect(throws: VoiceIssue.ended(.permissionDenied)) { try await fixture.workspace.startVoiceCall() }
            #expect(fixture.workspace.voiceViewState.phase == .failed(.ended(.permissionDenied)))
            #expect(fixture.voice.canStart)
        }
        #expect(!fixture.signal.sent.contains { if case .media(.offer) = $0 { true } else { false } })
        denied = false
        try await fixture.workspace.startVoiceCall()
        #expect(fixture.workspace.voiceViewState.phase == .connecting)
        try await fixture.workspace.performVoice(.hangUp)
        try await fixture.checkLibrary()
    }

    /// 拨给另一版信令的 Mac，它接听报的版本不同：手机挂断并显示"请更新"。
    @Test func 另一版的Mac接听_挂断并说请更新() async throws {
        let media = Media(), fixture = try await Fixture(makeMedia: { media })
        defer { fixture.app.services.cancelBackgroundWork() }
        try await fixture.workspace.startVoiceCall()
        let session = try #require(fixture.voice.session)
        await fixture.voice.receive(fixture.signal.event(.media(signal: .answer(value: .init(sdp: "answer", version: VoiceSignalFormat.callVersion + 1))), session: session))
        try await eventually("挂断") { fixture.voice.phone == nil }
        #expect(fixture.workspace.voiceViewState.phase == .failed(.relayUnsupported))
        #expect(fixture.workspace.voiceViewState.presentation().issues.contains { String(localized: $0.message).contains("请更新") })
        #expect(fixture.signal.sent.contains { if case .media(.hangup(reason: .protocolRejected)) = $0 { true } else { false } })
        try await fixture.checkLibrary()
    }
}
#endif
