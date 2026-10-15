import CueStore
import Foundation
import Testing
@testable import CuePad

#if os(macOS)
/// 斜杠命令的进度一行（一处规则 `MacDelivery.commandProgress`）：失败写原因，之后有新的请求或对话就收起。
struct CommandProgressTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func progress() async throws -> MacDelivery.CommandProgress? {
        MacDelivery.commandProgress(try await store.deliveryRequests(toSession: "atlas"), messages: try await store.piMessages(of: "atlas"), at: app.services.speech)
    }

    /// 扩展执行失败（它报 `failed: <原因>`）：写"/compact 没执行成功：<原因>"；之后有新的请求、对话里多了话（终端里又说了一句），就收起。
    @Test func 命令失败写原因_之后有新请求或对话就收起() async throws {
        let services: AppServices = app.services
        let ext = try await app.host.connect("atlas", cwd: "/work/atlas")
        ext.onCommand = { _, command in
            command["t"] as? String == "command" ? ["ok": false, "error": "failed: Nothing to compact (session too small)"] : ["ok": true, "delivered": "immediate"]
        }
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }
        let local = SendTarget(kind: .piSession, name: "atlas", ref: "atlas")

        let compact = try await store.requestDelivery("/compact", to: local, on: TestApp.hostID, mode: .command)
        let failed = try await services.store.outcome(of: compact.id)
        #expect(try await progress()?.text(sync: app.services.syncStatus) == "/compact 没执行成功：Nothing to compact (session too small)")

        let said = try #require(failed.completedAt).addingTimeInterval(0.001)
        try await store.writePiTranscript(PiTranscript(
            sessionID: "atlas", messages: [PiChatMessage(sessionID: "atlas", entryID: "u1", seq: 1, role: .user, text: "终端里说的", at: said)],
            recap: PiRecap()))
        #expect(try await progress() == nil)

        let again = try await store.requestDelivery("/compact", to: local, on: TestApp.hostID, mode: .command)
        _ = try await services.store.outcome(of: again.id)
        #expect(try await progress() != nil)
        _ = try await services.store.outcome(of: try await store.requestDelivery("你好", to: local, on: TestApp.hostID, mode: .send).id)
        #expect(try await progress() == nil)
        // 时间只到毫秒：同一毫秒里先命令后说话，按写下的先后，最新的仍是那句话
        var requests = try await store.deliveryRequests(toSession: "atlas")
        requests[requests.count - 1].createdAt = requests[requests.count - 2].createdAt
        #expect(MacDelivery.commandProgress(requests, messages: try await store.piMessages(of: "atlas"), at: app.services.speech) == nil)
    }
}
#endif
