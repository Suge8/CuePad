import CueStore
import Foundation
import Testing
@testable import CuePad

/// 改会话名：发一条 /name 斜杠命令让 Pi 改（会话名只来自 Pi）；改名在路上时行上就是新名，没改成回到旧名并写原因，
/// Pi 改好之后以会话记录为准。
@MainActor
struct SessionRenameTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var settings: AppSettings { app.services.settings }

    private func record(title: String) async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: title)
    }

    private func item() async throws -> PiSessionListItem {
        try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
    }

    private func title() async throws -> String {
        let item = try await item()
        return PiRename.title(of: item.state, request: item.delivery)
    }

    @Test func 改名在路上时行上是新名() async throws {
        try await record(title: "atlas")
        let request = try await app.services.rename(try await item().state, to: "  排队调度\n")

        #expect(request.content == "/name 排队调度")
        #expect(request.mode == .known(.command))
        #expect(try await title() == "排队调度")
    }

    @Test func 没改成回到旧名_行上写原因() async throws {
        try await record(title: "atlas")
        let request = try await app.services.rename(try await item().state, to: "排队调度")
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in .failed("Pi 已经退出") }
        try await executor.start()
        defer { Task { await executor.stop() } }
        for try await status in store.observe([.deliveryRequests], { try $0.deliveryRequest(request.id)?.status }) where status == .known(.failed) {
            break
        }

        let item = try await item()
        #expect(PiRename.title(of: item.state, request: item.delivery) == "atlas")
        let shown = settings.shown(item)
        #expect(PiRowLine.of(item.state, draft: nil, end: nil, undelivered: shown.undelivered(item.delivery)) == .failed("没能改名：Pi 已经退出"))
    }

    @Test func Pi改好之后以会话记录为准() async throws {
        try await record(title: "atlas")
        let request = try await app.services.rename(try await item().state, to: "排队调度")
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in .succeeded }
        try await executor.start()
        defer { Task { await executor.stop() } }
        for try await status in store.observe([.deliveryRequests], { try $0.deliveryRequest(request.id)?.status }) where status == .known(.succeeded) {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
        try await record(title: "排队调度")
        #expect(try await title() == "排队调度")

        // 之后在终端里又改了名：以 Pi 为准
        try await record(title: "调度")
        #expect(try await title() == "调度")
    }
}
