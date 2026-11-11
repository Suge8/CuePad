#if os(macOS)
@testable import CueStore
@testable import CueBridge
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 从回复框写下消息；在执行器已有的准备回调边界重现扩展变更与期限交错，不改生产调度或增加测试开关。
@MainActor
@Suite(.releasesLibraries)
struct DeliveryDispatchTests {
    @Test func 保留现有会话后再次升级且到期_明确失败不悬置() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let store = app.services.store
        let ext = try await app.host.connect("changing-session", cwd: app.directory.path)
        let workspace = Workspace(services: app.services)
        let target = SendTarget(kind: .piSession, name: "changing", ref: ext.sessionID)
        await workspace.speak("不要在升级后误派", to: .session(target, host: TestApp.hostID, mode: .send, card: nil)).value
        let request = try #require(try await store.deliveryRequests().first)
        let executor = DeliveryExecutor(store: store, hostID: TestApp.hostID, timing: clock.timing, onIssue: { Issue.record("\($0)") }, preparation: { request in
            await MainActor.run {
                if request.handledBy != nil {
                    app.bridge.update(ext.id) { $0.upgrading = true }
                    clock.advance(.seconds(DeliveryRequest.phaseLimit + 1))
                }
                return MacDeliveryPreparation(bridge: app.bridge).current(request)
            }
        }) { _, _ in
            Issue.record("已到期且目标在升级，不应交给执行回调")
            return .succeeded
        }
        defer { ext.close(bye: "quit"); app.bridge.stop(); app.services.cancelBackgroundWork() }
        try await executor.start()
        let failed = try await eventually(store, { try $0.deliveryRequest(request.id) }) { $0?.status == .known(.failed) }
        #expect(failed?.handledBy == nil)
        #expect(Said.request(try #require(failed)).trip(at: .always(at: clock.now)) == .failed(.reported("到期仍未派发（会话扩展正在升级），没有发出，可以重发")))
        #expect(ext.messages.isEmpty)
        await executor.stop()
    }
}
#endif
