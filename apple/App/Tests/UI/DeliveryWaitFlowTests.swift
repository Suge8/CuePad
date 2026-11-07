#if os(macOS)
@testable import CueStore
import CueTestSupport
import CueText
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import CuePad

/// 回复框说的话在 Mac 上等前提、等不到时，气泡上写的没送达原因（`Said.trip`）：说清是什么没到，可以重发。
@MainActor
struct DeliveryWaitFlowTests {
    /// 取附件那一步返回了、文件却没落到这台 Mac：这一次就写回没送达，原因说附件取过了仍不在，不反复重取空转到期限。
    @Test func 附件取过了仍不在这台Mac_气泡写没送达原因_只取一次() async throws {
        let app = TestApp()
        let services: AppServices = app.services
        let atlas = try await app.host.connect("atlas", cwd: "/work/atlas")
        let key = AttachmentKey.make(hash: String(repeating: "c", count: 64), format: "png")
        let fetches = Mutex(0)
        app.sync.fetching.withLock {
            $0 = { _ in
                fetches.withLock { $0 += 1 }
                return URL(filePath: "/nonexistent/\(key)")  // 说取到了，库里却没有
            }
        }
        try await services.executor.start()
        defer {
            atlas.close(bye: "quit")
            app.pi.stop()
            services.cancelBackgroundWork()
        }

        var box = ComposerDraft(text: "看这张截图", files: [DraftFile(key: key, name: "")])
        let binding = Binding(get: { box }, set: { box = $0 })
        let listener = Listener.session(SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), host: TestApp.hostID, mode: .send, card: nil)
        await Workspace(services: services).speak(to: listener, from: binding) { $0.stored }.value
        let failed = try await eventually(services.store, { try $0.deliveryRequests().first }) { $0?.status == .known(.failed) }
        let shown = Said.request(try #require(failed)).trip(at: services.speech)
        #expect(shown == .failed(.reported(DeliveryPreparation.attachmentMissing.text)))
        await quietPeriod(.milliseconds(300))
        #expect(fetches.withLock { $0 } == 1, "不再见缺就取")
        #expect(atlas.messages.isEmpty)
        await services.executor.beginStop()()
    }
}

extension UpgradePreparationTests {
    /// 现有会话等到就绪了，却一直排在另一处后面没轮到，过了派发期限：没送达的原因不把"准备就绪"当成在等什么。
    @Test func 会话就绪后排队到期_气泡原因不带在等什么() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing), store = app.services.store
        let (target, old) = try await oldSession(app)
        defer { old.crash(); app.pi.stop(); app.services.cancelBackgroundWork() }
        let workspace = Workspace(services: app.services)
        let request = try await workspace.said(ComposerDraft(text: "排到期了的一句"), to: target, mode: .send)
        try await app.services.executor.start()
        let waiting = try await prepared(request, in: app)
        guard waiting.status == .known(.preparing) else { Issue.record("应在等会话升级"); await app.services.executor.beginStop()(); return }

        // 另一处一直等 ACK，占着执行通道
        let blocker = try await app.host.connect("blocking-session", cwd: app.directory.path)
        blocker.onCommand = { _, command in command["t"] as? String == "send" ? nil : ["ok": true] }
        let recorder = try await app.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: blocker.sessionID, state: .settled)
        let blockingTarget = try #require(try await store.allPiSessionStates().first { $0.sessionID == blocker.sessionID })
        _ = try await workspace.said(ComposerDraft(text: "在另一处等ACK"), to: blockingTarget, mode: .send)
        try await eventually("另一处已接手") { blocker.messages.count == 1 }

        old.close(bye: "reload")
        let ready = try await app.host.connect(target.sessionID, cwd: app.directory.path)
        try await eventually("会话就绪") { try await store.deliveryRequest(request.id)?.reason == DeliveryPreparation.ready }
        let due = try #require(waiting.dispatchDeadline)
        clock.advance(.seconds(due.timeIntervalSince(clock.now) + 1))
        let failed = try await eventually(store, { try $0.deliveryRequest(request.id) }) { $0?.status == .known(.failed) }
        let shown = Said.request(try #require(failed)).trip(at: app.services.speech)
        #expect(shown == .failed(.reported("到期仍未派发，没有发出，可以重发")))
        #expect(ready.messages.isEmpty)
        await app.services.executor.beginStop()()
    }
}
#endif
