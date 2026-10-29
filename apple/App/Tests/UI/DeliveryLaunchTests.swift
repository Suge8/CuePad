#if os(macOS)
import CueAgent
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// #43 复审：创建会话与提交首句是两步，第二步拒绝不能撤销已发生的第一步。
@MainActor
struct DeliveryLaunchTests {
    @Test(arguments: ["no_auth", "unconfirmed_turn"])
    func 会话已创建但首句拒绝_保留未知_不能删除重发或自动再开(reason: String) async throws {
        let app = TestApp(), store = app.services.store
        defer {
            for ext in app.host.extensions.values { ext.close(bye: "quit") }
            app.pi.stop(); app.services.cancelBackgroundWork()
        }
        try await app.offersPi()
        app.host.openingRejection = reason
        let task = try await store.createTask("检查发布结果")
        let token = UUID().uuidString
        let launch = PiLaunch(project: Project.defaultID, prompt: task.body, token: token)
        let workspace = Workspace(services: app.services)
        await workspace.speak(launch.stored, to: .session(
            SendTarget(kind: .piSession, name: "发布", ref: nil), host: TestApp.hostID, mode: .start, card: task.id)).value
        let request = try #require(try await store.deliveryRequests().first)
        try await app.services.executor.start()
        let result = try await store.outcome(of: request)
        #expect(app.pi.sessions.count == 1)
        #expect(result.status == .known(.unconfirmed))
        #expect(try await store.launchingLeaves([task.id]) == [task.id])
        await workspace.resend(.request(result), restoringInto: app.services.settings.replyDraftBinding(for: task.id)).value
        #expect(workspace.notice?.isError == true)
        #expect(try await store.deliveryRequests().map(\.id) == [request.id])
        let host = TestApp.hostID
        try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        let repeated = try #require(await CueTools(store: store, wait: 0).call("task", [
            "action": "start", "task": task.id.uuidString, "fresh": true,
        ]))
        #expect(repeated.isError)
        #expect(try await store.deliveryRequests().map(\.id) == [request.id])
        await app.services.executor.beginStop()()
    }
}
#endif
