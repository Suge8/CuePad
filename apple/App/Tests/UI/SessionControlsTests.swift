import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话页里换模型与思考强度：经模型胶囊同一个入口（`AppServices.configure`）写请求，显示只由会话记录与发给它的投送请求推出（不另存界面状态）。
/// 换了之后胶囊立即显示新值并标着在路上；没换成回到会话当前的值并写原因。
struct SessionControlsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private let opus = PiModelOption(key: PiModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.low, .high])
    private let luna = PiModelOption(key: PiModelKey(provider: "openai", id: "luna"), name: "Luna", thinkingLevels: [.off, .high])

    private func session() async throws -> PiSessionState {
        let recorder = try await app.runtimeRecorder(on: "mac-a")
        try await recorder.update(
            sessionID: "atlas", state: .settled, title: "atlas", directory: "/w/atlas",
            modelState: PiModelState(model: opus, thinking: .known(.low), models: [opus, luna]))
        return try #require(try await store.piSessionPage(PiSessionQuery()).items.first?.state)
    }

    /// 会话页读到的模型与思考强度（与页面同一次读取）。
    private func shown(_ session: PiSessionState) async throws -> PiConfigShown {
        try await SessionDigest.read(session.id, sessionID: session.sessionID, from: store).config(at: .always())
    }

    /// Mac 执行器按给定结果写回，等到这条有结果。
    private func execute(_ request: DeliveryRequest, failing reason: String) async throws -> DeliveryRequest {
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _, _ in .failed(.verbatim(reason)) }
        try await executor.start()
        defer { Task { await executor.stop() } }
        for try await current in store.observe({ try $0.deliveryRequest(request.id) }) {
            if let current, !current.isOpen { return current }
        }
        throw CancellationError()
    }

    /// 选择题：Agent 本身允许自己填的（经同步记录到手机也还认得），回复框也能答，答案是文字；不允许的回复框收成"先在上面作答"。
    @Test(arguments: [true, false])
    func 允许自己填的选择题_回复框也能作答(allowsOther: Bool) async throws {
        let question = PiQuestion(promptID: "p-1", kind: .select, text: "喝什么？", options: ["茶", "咖啡"], allowsOther: allowsOther)
        let recorder = try await app.runtimeRecorder(on: "mac-a")
        try await recorder.update(sessionID: "atlas", state: .waitingForUser, title: "atlas", question: question)
        let session = try #require(try await store.allPiSessionStates().first)

        #expect(MacDelivery.reply(to: session) == (allowsOther ? .answer(question) : .answerAbove))
    }

    @Test func 换模型_立即显示新值_没换成回到当前值写原因_结束了照样能换() async throws {
        let atlas = try await session()
        let request = try await app.services.configure(PiConfig(model: luna.key, thinking: .high), for: atlas)
        #expect(try await shown(atlas) == PiConfigShown(model: luna, thinking: .high, pending: true, failure: nil))

        _ = try await execute(request, failing: "Pi 没在运行")
        #expect(try await shown(atlas) == PiConfigShown(model: opus, thinking: .low, pending: false, failure: .reported("Pi 没在运行")))

        try await PiStateRecorder(store: store, hostID: "mac-a").end(sessionID: "atlas")
        let ended = try #require(try await store.allPiSessionStates().first)
        #expect(ended.state == .known(.ended))
        _ = try await app.services.configure(PiConfig(model: luna.key), for: ended)
        #expect(try await shown(ended).model == luna)
    }
}
