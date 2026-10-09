import CueStore
import Foundation
import Testing
@testable import CuePad

/// 改会话名是会话设置：一条带名字的配置请求让 Pi 改（会话名只来自 Pi），与改模型、思考强度同一条路——不算发给会话的话，
/// 对话里不出气泡。改名在路上时行上就是新名，没改成回到旧名并写原因，Pi 改好之后以会话记录为准。
@MainActor
struct SessionRenameTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func record(title: String) async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: title)
    }

    private func item() async throws -> PiSessionListItem {
        try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
    }

    private func title() async throws -> String {
        let item = try await item()
        return PiRename.title(of: item.state, request: item.rename)
    }

    private func finish(_ request: DeliveryRequest, _ outcome: DeliveryOutcome) async throws -> DeliveryExecutor {
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in outcome }
        try await executor.start()
        for try await open in store.observe([.deliveryRequests], { try $0.deliveryRequest(request.id)?.isOpen }) where open == false { break }
        return executor
    }

    @Test func 改名在路上时行上是新名_不算发给会话的话() async throws {
        try await record(title: "atlas")
        let request = try await app.services.rename(try await item().state, to: "  排队调度\n")

        #expect(request.config == PiConfig(name: "排队调度"))
        #expect(try await title() == "排队调度")
        let item = try await item()
        #expect(item.delivery == nil)
        #expect(PiChat.outgoing([request], messages: []).isEmpty)
    }

    @Test func 没改成回到旧名_行上写原因() async throws {
        try await record(title: "atlas")
        let request = try await app.services.rename(try await item().state, to: "排队调度")
        let executor = try await finish(request, .failed("Pi 已经退出"))
        defer { Task { await executor.stop() } }

        let item = try await item()
        #expect(PiRename.title(of: item.state, request: item.rename) == "atlas")
        #expect(PiRowLine.of(item.state, draft: nil, end: nil, failure: PiRename.failure(item.rename, seen: nil)) == .failed("没能改名：Pi 已经退出"))
        #expect(PiRename.failure(item.rename, seen: .now.addingTimeInterval(1)) == nil)
    }

    @Test func Pi改好之后以会话记录为准() async throws {
        try await record(title: "atlas")
        let request = try await app.services.rename(try await item().state, to: "排队调度")
        let executor = try await finish(request, .succeeded)
        defer { Task { await executor.stop() } }
        try await Task.sleep(for: .milliseconds(5))
        try await record(title: "排队调度")
        #expect(try await title() == "排队调度")

        // 之后在终端里又改了名：以 Pi 为准
        try await record(title: "调度")
        #expect(try await title() == "调度")
    }
}
