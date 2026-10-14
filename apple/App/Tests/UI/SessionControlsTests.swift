import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话页里换模型与思考强度的显示：只由会话记录与发给它的投送请求推出（不另存界面状态）。
/// 换了之后胶囊立即显示新值并标着在路上；没换成回到会话当前的值并写原因。
struct SessionControlsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private let opus = PiModelOption(key: PiModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.low, .high])
    private let luna = PiModelOption(key: PiModelKey(provider: "openai", id: "luna"), name: "Luna", thinkingLevels: [.off, .high])

    private func session() async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(
            sessionID: "atlas", state: .settled, title: "atlas", directory: "/w/atlas",
            modelState: PiModelState(model: opus, thinking: .known(.low), models: [opus, luna]))
        return try #require(try await store.piSessionPage(PiSessionQuery()).items.first?.state)
    }

    /// 会话页读到的模型与思考强度（与页面同一次读取）。
    private func shown(_ session: PiSessionState) async throws -> PiConfigShown {
        try await SessionDigest.read(session.id, sessionID: session.sessionID, from: store).config
    }

    private func target(_ session: PiSessionState) -> SendTarget {
        SendTarget(kind: .piSession, name: session.title, ref: session.sessionID)
    }

    /// Mac 执行器按给定结果写回，等到这条有结果。
    private func execute(_ request: DeliveryRequest, failing reason: String) async throws -> DeliveryRequest {
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in .failed(reason) }
        try await executor.start()
        defer { Task { await executor.stop() } }
        for try await current in store.observe({ try $0.deliveryRequest(request.id) }) {
            if let current, !current.isOpen { return current }
        }
        throw CancellationError()
    }

    @Test func 换了模型_立即显示新值并标在路上() async throws {
        let atlas = try await session()
        _ = try await store.requestConfig(PiConfig(model: luna.key, thinking: .high), to: target(atlas), on: atlas.hostID)

        #expect(try await shown(atlas) == PiConfigShown(model: luna, thinking: .high, pending: true, failure: nil))
    }

    @Test func 没换成_回到会话当前的值并写原因() async throws {
        let atlas = try await session()
        let request = try await store.requestConfig(PiConfig(thinking: .high), to: target(atlas), on: atlas.hostID)
        _ = try await execute(request, failing: "Pi 没在运行")

        #expect(try await shown(atlas) == PiConfigShown(model: opus, thinking: .low, pending: false, failure: "Pi 没在运行"))
    }

}

#if os(iOS)
#endif
