#if os(iOS)
import CueStore
import Testing
import UIKit
@testable import CuePad

/// #99：手机的按钮入口、真实网页媒体与隔离库；中转、远端及权限等待用替身。
@Suite(.serialized) @MainActor struct VoiceAudioLifecycleTests {
    final class Media: VoiceMedia {
        var onEvent: (VoicePeer.Event) -> Void = { _ in }
        var offerGate: AuditGate?
        var closeGate: AuditGate?
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
        func play() async throws {}
        func setMuted(_ value: Bool) async throws {}
        func close() async throws { await closeGate?.wait(); closed = true }
    }

    final class Fixture {
        let app = TestApp()
        let signal = AuditSignaling()
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

    @Test func realWebAudioReopensAndIgnoresOldCallbacks() async throws {
        var nextMedia: any VoiceMedia = Media()
        let fixture = try await Fixture(makeMedia: { nextMedia }), workspace = fixture.workspace
        defer { fixture.app.services.cancelBackgroundWork() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await eventually("App 已可接收接通点击") { UIApplication.shared.applicationState == .active }
        let file = fixture.app.directory.appending(path: "silence.wav")
        try VoicePeer.wav(Data(repeating: 0, count: 48000)).write(to: file)
        var oldCallback: ((VoicePeer.Event) -> Void)?
        for _ in 0..<2 {
            let media = VoicePeer(source: .file(file), recording: nil)
            nextMedia = media
            try await workspace.startVoiceCall()
            let before = fixture.voice.inputSamples.count
            oldCallback?(.ended(.audioInterrupted))
            try await eventually("网页继续采样") { fixture.voice.inputSamples.count > before || fixture.voice.phone == nil }
            #expect(workspace.phoneVoice.phase == .connecting)
            #expect(!fixture.voice.canStart)
            oldCallback = media.onEvent
            await workspace.hangUpVoiceCall()
            #expect(workspace.phoneVoice.phase == .ended(reason: .hungUp))
            #expect(fixture.voice.canStart)
        }
        try await fixture.checkLibrary()
    }

    @Test(arguments: [false, true])
    func interruptionKeepsItsReasonAndClosingExcludesReconnect(whileStarting: Bool) async throws {
        let media = Media(), gate = AuditGate(), closeGate = AuditGate()
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
        #expect(fixture.workspace.phoneVoice.phase == .closing)
        await #expect(throws: VoiceIssue.busy) { try await fixture.workspace.startVoiceCall() }
        gate.open()
        _ = await start.result
        closeGate.open()
        try await eventually("中断清理完成") { fixture.voice.phone == nil }
        #expect(fixture.workspace.phoneVoice.phase == .ended(reason: .audioInterrupted))
        #expect(fixture.signal.sent.contains { if case .media(.hangup(reason: .audioInterrupted)) = $0 { true } else { false } })
        let next = Media()
        nextMedia = next
        try await fixture.workspace.startVoiceCall()
        oldCallback(.ended(.audioInterrupted))
        #expect(fixture.workspace.phoneVoice.phase == .connecting)
        #expect(!next.closed)
        await fixture.workspace.hangUpVoiceCall()
        #expect(fixture.workspace.phoneVoice.phase == .ended(reason: .hungUp))
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
            #expect(fixture.workspace.phoneVoice.phase == .failed(.ended(.permissionDenied)))
            #expect(fixture.voice.canStart)
        }
        #expect(!fixture.signal.sent.contains { if case .media(.offer) = $0 { true } else { false } })
        denied = false
        try await fixture.workspace.startVoiceCall()
        #expect(fixture.workspace.phoneVoice.phase == .connecting)
        await fixture.workspace.hangUpVoiceCall()
        try await fixture.checkLibrary()
    }
}
#endif
