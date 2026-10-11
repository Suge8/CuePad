import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话显示的状态把"发给它、还没被它的状态吸收的投送请求"算进去（全 App 的会话行、状态点、会话页顶栏同一条规则）：
/// 发出当场就是"发送中"，不等 Mac 执行、写回、同步；会话进入处理中后让位给会话状态；没送达写"没能送达"。
@MainActor
struct PiDeliveryStatusTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func session(_ state: PiWorkState) async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: state, title: "atlas")
        return try #require(try await store.piSessionPage(PiSessionQuery()).items.first?.state)
    }

    @discardableResult
    private func say(_ text: String, to session: PiSessionState) async throws -> DeliveryRequest {
        try await store.requestDelivery(
            text, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID, mode: .send)
    }

    /// 列表里这一行此刻显示的状态词（与 Agent 页、项目页、Mac 侧栏读的是同一个查询）。
    private func rowLabel() async throws -> String {
        let item = try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
        return app.services.settings.shown(item.state, delivery: item.delivery).label
    }

    @Test func 发出后列表行立即是发送中() async throws {
        let atlas = try await session(.settled)
        try await say("看看 scheduler", to: atlas)

        #expect(try await rowLabel() == "发送中")
    }

    @Test func 会话进入处理中后让位给会话状态() async throws {
        let atlas = try await session(.settled)
        try await say("看看 scheduler", to: atlas)
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .thinking, title: "atlas")

        #expect(try await rowLabel() == "思考中")
    }

    @Test func 发给已结束的会话_写正在唤醒() async throws {
        let atlas = try await session(.ended)
        try await say("接着做", to: atlas)

        #expect(try await rowLabel() == "正在唤醒")
    }

    @Test func 没送达_写没能送达() async throws {
        let atlas = try await session(.settled)
        let request = try await say("看看 scheduler", to: atlas)
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in .failed("Pi 没在运行") }
        try await executor.start()
        defer { Task { await executor.stop() } }
        for try await status in store.observe({ try $0.deliveryRequest(request.id)?.status }) where status == .known(.failed) {
            break
        }

        #expect(try await rowLabel() == "没能送达")
    }
}
