import CueStore
import Foundation
import Testing
@testable import CuePad

/// 斜杠命令不进对话、不进发送记录；它的进度只在回复框上方一行短暂显示（一处规则 `MacDelivery.commandProgress`）：
/// 在路上写"正在执行 /compact…"，没成功写原因，成功就消失（结果若在会话文件里，对话里自然有）。只看最近一条命令。
struct CommandProgressTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    private let target = SendTarget(kind: .piSession, name: "atlas", ref: "atlas")

    private func command(_ line: String, on host: String = "mac-wait") async throws -> DeliveryRequest {
        try await store.requestDelivery(line, to: target, on: host, mode: .command)
    }

    private func finish(_ request: DeliveryRequest, _ outcome: DeliveryOutcome, host: String) async throws {
        let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { _ in }) { _ in outcome }
        try await executor.start()
        defer { Task { await executor.stop() } }
        _ = try await eventually(store, { try $0.deliveryRequest(request.id)?.isOpen }) { $0 == false }
    }

    @Test func 在路上写正在执行_只取命令的名字() async throws {
        _ = try await command("/greet 很长很长的参数")

        #expect(MacDelivery.commandProgress(try await store.deliveryRequests(toSession: "atlas")) == .running("/greet"))
        #expect(MacDelivery.commandProgress(try await store.deliveryRequests(toSession: "atlas"))?.text == "正在执行 /greet…")
    }

    @Test func 没成功写原因_成功就消失_只看最近一条() async throws {
        let failing = try await command("/compact", on: "mac-fail")
        try await finish(failing, .failed("没有可压缩的内容"), host: "mac-fail")
        var progress = MacDelivery.commandProgress(try await store.deliveryRequests(toSession: "atlas"))
        #expect(progress == .failed(command: "/compact", reason: "没有可压缩的内容"))
        #expect(progress?.text == "/compact 没执行成功：没有可压缩的内容")

        let done = try await command("/reload", on: "mac-ok")
        try await finish(done, .succeeded, host: "mac-ok")
        progress = MacDelivery.commandProgress(try await store.deliveryRequests(toSession: "atlas"))
        #expect(progress == nil)  // 最近一条成功了：旧的失败不再提示
    }

    @Test func 说话与设置请求不算命令() async throws {
        _ = try await store.requestDelivery("你好", to: target, on: "mac-wait", mode: .send)
        _ = try await store.requestConfig(PiConfig(thinking: .low), to: target, on: "mac-wait")

        #expect(MacDelivery.commandProgress(try await store.deliveryRequests(toSession: "atlas")) == nil)
    }
}
