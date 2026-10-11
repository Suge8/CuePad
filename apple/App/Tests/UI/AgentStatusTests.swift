import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话显示的状态以会话自己为准：它在跑时，排队等这一轮做完再送的话只是一个小标记，不把整行盖成"发送中"；
/// 没能送达留到你看过这个会话（或重发）为止，不会因为会话之后动过就自己消失。
@MainActor
struct AgentStatusTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var settings: AppSettings { app.services.settings }

    private func record(_ state: PiWorkState) async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: state, title: "atlas")
    }

    private func item() async throws -> PiSessionListItem {
        try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
    }

    @discardableResult
    private func say(_ text: String, mode: DeliveryMode) async throws -> DeliveryRequest {
        try await store.requestDelivery(text, to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), on: "mac-a", mode: mode)
    }

    @Test func 在跑的会话收到排队的话_状态仍是它自己的_另有排队标记() async throws {
        try await record(.tool)
        try await say("改完再看看登录回调", mode: .followUp)

        let shown = settings.shown(try await item())
        #expect(shown.label == "运行工具")
        #expect(shown.note == "你的话排队中")
    }

    @Test func 没能送达留到看过为止_会话之后动过也不消失() async throws {
        try await record(.settled)
        let request = try await say("备份一下线上库", mode: .send)
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in .failed("Pi 已经退出") }
        try await executor.start()
        defer { Task { await executor.stop() } }
        for try await status in store.observe({ try $0.deliveryRequest(request.id)?.status }) where status == .known(.failed) {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
        try await record(.thinking)
        try await record(.settled)

        #expect(settings.shown(try await item()).label == "没能送达")

        settings.markSeen(try await item().state, at: .now.addingTimeInterval(1))
        #expect(settings.shown(try await item()).label != "没能送达")
    }
}
