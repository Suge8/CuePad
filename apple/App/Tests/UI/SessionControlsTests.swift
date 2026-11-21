import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SessionControlsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private let opus = ModelOption(key: ModelKey(provider: "anthropic", id: "opus"), name: "Opus", thinkingLevels: [.low, .high])
    private let luna = ModelOption(key: ModelKey(provider: "openai", id: "luna"), name: "Luna", thinkingLevels: [.off, .high])

    private func session() async throws -> SessionState {
        let recorder = try await app.runtimeRecorder(on: "mac-a")
        try await recorder.update(
            sessionID: "atlas", state: .settled, title: "atlas", directory: "/w/atlas",
            modelState: ModelState(model: opus, thinking: .known(.low), models: [opus, luna]))
        return try #require(try await store.sessionPage(SessionQuery()).items.first?.state)
    }

    private func shown(_ session: SessionState) async throws -> ConfigShown {
        try await SessionDigest.read(session.id, sessionID: session.sessionID, from: store).config(at: .always())
    }

    private func execute(_ request: DeliveryRequest, failing reason: String) async throws -> DeliveryRequest {
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _, _ in .failed(.verbatim(reason)) }
        try await executor.start()
        defer { await executor.stop() }
        return try #require(try await eventually(store, { try $0.deliveryRequest(request.id) }) { $0.map { !$0.isOpen } ?? false })
    }

    @Test(arguments: [true, false])
    func 允许自己填的选择题_回复框也能作答(allowsOther: Bool) async throws {
        let question = Question(promptID: "p-1", kind: .select, text: "喝什么？", options: ["茶", "咖啡"], allowsOther: allowsOther)
        let recorder = try await app.runtimeRecorder(on: "mac-a")
        try await recorder.update(sessionID: "atlas", state: .waitingForUser, title: "atlas", question: question)
        let session = try #require(try await store.allSessionStates().first)

        #expect(MacDelivery.reply(to: session) == (allowsOther ? .answer(question) : .answerAbove))
    }

    @Test func 换模型_立即显示新值_没换成回到当前值写原因_再做别的就不再说_结束了照样能换() async throws {
        let atlas = try await session()
        let request = try await app.services.configure(SessionConfig(model: luna.key, thinking: .high), for: atlas)
        #expect(try await shown(atlas) == ConfigShown(model: luna, thinking: .high, pending: true, failure: nil))

        _ = try await execute(request, failing: "Pi 没在运行")
        #expect(try await shown(atlas) == ConfigShown(model: opus, thinking: .low, pending: false, failure: "没换成 Luna：Pi 没在运行"))
        _ = try await app.services.stop(atlas)
        #expect(try await shown(atlas).failure == nil)

        try await StateRecorder(store: store, hostID: "mac-a").end(sessionID: "atlas")
        let ended = try #require(try await store.allSessionStates().first)
        #expect(ended.state == .known(.ended))
        _ = try await app.services.configure(SessionConfig(model: luna.key), for: ended)
        #expect(try await shown(ended).model == luna)
    }

    @Test func 换模型还在路上_后发的改强度没换成_仍显示要换的模型_送达后强度收进新模型有的档() async throws {
        let atlas = try await session()
        let switching = try await app.services.configure(SessionConfig(model: luna.key), for: atlas)
        let thinking = try await app.services.configure(SessionConfig(thinking: .high), for: atlas)
        let confirm = AsyncStream<Void>.makeStream()
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { [stream = confirm.stream] request, _ in
            guard request.id == switching.id else { return .failed(.verbatim("Pi 没在运行")) }
            return .confirming { _ in
                for await _ in stream { break }
                return .succeeded
            }
        }
        try await executor.start()
        defer { Task { await executor.stop() } }
        _ = try await eventually(store, { try $0.deliveryRequest(thinking.id) }) { $0.map { !$0.isOpen } ?? false }
        #expect(try await shown(atlas) == ConfigShown(model: luna, thinking: .off, pending: true, failure: "没换成 思考 高：Pi 没在运行"))

        confirm.continuation.yield()
        _ = try await eventually(store, { try $0.deliveryRequest(switching.id) }) { $0?.status == .known(.succeeded) }
        try await app.runtimeRecorder(on: "mac-a").update(
            sessionID: "atlas", state: .settled, title: "atlas", directory: "/w/atlas",
            modelState: ModelState(model: luna, thinking: .known(.low), models: [opus, luna]))
        let delivered = try await shown(atlas)
        #expect(delivered.model == luna && delivered.thinking == .off && !delivered.pending)
    }
}
