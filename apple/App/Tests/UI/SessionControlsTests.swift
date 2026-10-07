import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话页里换模型与思考强度的显示：只由会话记录与发给它的投送请求推出（不另存界面状态）。
/// 换了之后胶囊立即显示新值并标着在路上；没换成回到会话当前的值并写原因。
@MainActor
struct SessionControlsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private let opus = PiModelOption(key: PiModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.low, .high])
    private let luna = PiModelOption(key: PiModelKey(provider: "openai", id: "luna"), name: "Luna", thinkingLevels: [.off, .high])

    private func session() async throws -> PiSessionState {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas")
        var session = try #require(try await store.piSessionPage(PiSessionQuery()).items.first?.state)
        session.model = opus
        session.thinking = .known(.low)
        session.models = [opus, luna]
        return session
    }

    private func target(_ session: PiSessionState) -> SendTarget {
        SendTarget(kind: .piSession, name: session.title, ref: session.sessionID)
    }

    /// Mac 执行器按给定结果写回，等到这条有结果。
    private func execute(_ request: DeliveryRequest, failing reason: String) async throws -> DeliveryRequest {
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in .failed(reason) }
        try await executor.start()
        defer { Task { await executor.stop() } }
        for try await current in store.observe([.deliveryRequests], { try $0.deliveryRequest(request.id) }) {
            if let current, !current.isOpen { return current }
        }
        throw CancellationError()
    }

    @Test func 换了模型_立即显示新值并标在路上() async throws {
        let atlas = try await session()
        let request = try await store.requestConfig(PiConfig(model: luna.key, thinking: .high), to: target(atlas), on: atlas.hostID)

        let shown = SessionDigest(session: atlas, project: nil, deliveries: [request]).config

        #expect(shown == PiConfigShown(model: luna, thinking: .high, pending: true, failure: nil))
    }

    @Test func 没换成_回到会话当前的值并写原因() async throws {
        let atlas = try await session()
        let request = try await store.requestConfig(PiConfig(thinking: .high), to: target(atlas), on: atlas.hostID)
        let failed = try await execute(request, failing: "Pi 没在运行")

        let shown = SessionDigest(session: atlas, project: nil, deliveries: [failed]).config

        #expect(shown == PiConfigShown(model: opus, thinking: .low, pending: false, failure: "Pi 没在运行"))
    }

}

/// 会话右缘的刻度滑条：每条你发的话一个刻度（按先后），预览是它的第一行；你发的不到 6 条时不显示。
struct ChatScrubberMarksTests {
    private func entry(_ user: Bool, _ text: String) -> PiChatEntry { PiChatEntry(id: UUID(), isUser: user, text: text, meta: nil) }

    @Test func 每条你发的话一个刻度_预览是第一行() {
        let entries = (1...6).flatMap { [entry(true, "第 \($0) 问\n细节"), entry(false, "回答 \($0)")] }

        let marks = ChatScrubber.marks(entries)

        #expect(marks.map(\.preview) == (1...6).map { "第 \($0) 问" })
        #expect(marks.map(\.id) == entries.filter(\.isUser).map(\.id))
    }

    @Test func 不到6条不显示() {
        let entries = (1...5).map { entry(true, "第 \($0) 问") }
        #expect(ChatScrubber.marks(entries).isEmpty)
    }
}
