#if os(iOS)
import AVFoundation
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
        init() async throws {
            try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "mac-audit" }
            app.services.voice = VoiceService(services: app.services, signaling: signal)
            workspace = Workspace(services: app.services)
            saved = try await app.services.store.addCueMessage(.cue, text: "Keep this reply after the call")
        }
        func checkLibrary() async throws {
            #expect(try await app.services.store.cueMessages().map(\.id) == [saved.id])
            #expect(try await app.services.store.deliveryRequests().isEmpty)
        }
    }

    @Test func realWebAudioSurvivesEndedNotificationsAndReopens() async throws {
        let fixture = try await Fixture(), workspace = fixture.workspace
        defer { fixture.app.services.cancelBackgroundWork() }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let file = fixture.app.directory.appending(path: "silence.wav")
        try VoicePeer.wav(Data(repeating: 0, count: 48000)).write(to: file)
        var oldCallback: ((VoicePeer.Event) -> Void)?
        for _ in 0..<2 {
            let media = VoicePeer(source: .file(file), recording: nil)
            try await workspace.startVoiceCall { media }
            let before = fixture.voice.inputSamples.count
            oldCallback?(.ended(.audioInterrupted))
            let center = NotificationCenter.default, audio = AVAudioSession.sharedInstance()
            // 旧通知的 wire 值来自 AVAudioSession 合同；结束通知不能变成新的中断。
            let legacy = Notification.Name("AVAudioSessionInterruptionNotification")
            center.post(name: legacy, object: audio, userInfo: ["AVAudioSessionInterruptionTypeKey": 0, "AVAudioSessionInterruptionOptionKey": 1])
            center.post(name: legacy, object: NSObject(), userInfo: ["AVAudioSessionInterruptionTypeKey": 1, "AVAudioSessionInterruptionReasonKey": 0])
            center.post(name: AVAudioSession.didBecomeActiveNotification, object: audio)
            center.post(name: AVAudioSession.resumptionRecommendationNotification, object: audio)
            center.post(name: AVAudioSession.didBecomeInactiveNotification, object: NSObject())
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
        let fixture = try await Fixture(), media = Media(), gate = AuditGate(), closeGate = AuditGate()
        defer { gate.open(); closeGate.open(); fixture.app.services.cancelBackgroundWork() }
        media.closeGate = closeGate
        if whileStarting { media.offerGate = gate; media.failure = CancellationError() }
        let start = Task { try await fixture.workspace.startVoiceCall { media } }
        try await eventually("手机正在开始") { media.offered }
        if !whileStarting {
            try await start.value
            let session = try #require(fixture.voice.session)
            await fixture.voice.receive(fixture.signal.event(.media(signal: .answer(value: .init(sdp: "answer"))), session: session))
        }
        let oldCallback = media.onEvent
        oldCallback(.ended(.audioInterrupted))
        #expect(fixture.workspace.phoneVoice.phase == .closing)
        await #expect(throws: VoiceIssue.busy) { try await fixture.workspace.startVoiceCall { Media() } }
        gate.open()
        _ = await start.result
        closeGate.open()
        try await eventually("中断清理完成") { fixture.voice.phone == nil }
        #expect(fixture.workspace.phoneVoice.phase == .ended(reason: .audioInterrupted))
        #expect(fixture.signal.sent.contains { if case .media(.hangup(reason: .audioInterrupted)) = $0 { true } else { false } })
        let next = Media()
        try await fixture.workspace.startVoiceCall { next }
        oldCallback(.ended(.audioInterrupted))
        #expect(fixture.workspace.phoneVoice.phase == .connecting)
        #expect(!next.closed)
        await fixture.workspace.hangUpVoiceCall()
        #expect(fixture.workspace.phoneVoice.phase == .ended(reason: .hungUp))
        try await fixture.checkLibrary()
    }

    @Test func deniedPermissionCanBeRetriedWithoutChangingTheLibrary() async throws {
        let fixture = try await Fixture()
        defer { fixture.app.services.cancelBackgroundWork() }
        for _ in 0..<2 {
            let denied = Media(); denied.failure = VoicePeerError.microphoneDenied
            await #expect(throws: VoiceIssue.ended(.permissionDenied)) { try await fixture.workspace.startVoiceCall { denied } }
            #expect(fixture.workspace.phoneVoice.phase == .failed(.ended(.permissionDenied)))
            #expect(fixture.voice.canStart)
        }
        #expect(!fixture.signal.sent.contains { if case .media(.offer) = $0 { true } else { false } })
        try await fixture.workspace.startVoiceCall { Media() }
        #expect(fixture.workspace.phoneVoice.phase == .connecting)
        await fixture.workspace.hangUpVoiceCall()
        try await fixture.checkLibrary()
    }
}
#endif
