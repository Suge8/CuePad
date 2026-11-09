#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

@MainActor
@Suite(RealAgents.taped(.pi))
struct RealFirecodeTests {
    /// 指挥官照 `prompt` 调 FireCode 的 subagents 工具（开子代理或移除它），之后回 TOOL_DONE；子代理的任务（"子任务"）停在返回的闸门上，
    /// 指挥官收到它交回的结果照常回声。
    private func script(_ pi: PiProcess, _ prompt: String, _ action: String, worker: String) -> FakeGate {
        let arguments: [String: any Sendable] = action == "kill"
            ? ["action": "kill", "worker": worker] : ["action": "start", "worker": worker, "role": "工程师", "prompt": "子任务"]
        pi.model.on(prompt, .call("subagents", arguments), .say("TOOL_DONE"))
        let gate = pi.model.gate()
        pi.model.on({ $0.prompt == "子任务" }) { _ in .held(gate, then: .say("子任务做完")) }
        return gate
    }

    @Test func subagentsAreSummarizedOnTheMasterSessionAndTheirEventsAreNotYourPrompt() async throws {
        let pi = try await PiProcess(extraExtensions: [], firecode: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let log = ChangeLog(bridge)
        try await eventually("桥发现指挥官会话") { !bridge.sessions.isEmpty }

        let gate = script(pi, "派个子代理", "start", worker: "ui")
        try pi.prompt("派个子代理")
        try await eventually("子代理出现在指挥官会话的摘要里（或 subagents 工具报错）") {
            bridge.sessions.first?.subagents.map(\.name) == ["ui"] || pi.subagentsToolFailed
        }
        try pi.requireSubagentsTool()  // 指挥官没加载时立即带 FireCode 的提示原文失败
        let ui = try #require(bridge.sessions.first?.subagents.first)
        #expect(ui.role == "工程师" && ui.startedAt != nil && ui.model?.contains("/") == true)

        try await eventually("指挥官歇下、等子代理") {
            recap(of: bridge.sessions.first)?.lastReply == "TOOL_DONE" && bridge.sessions.first?.state == .delegating
        }
        let start = try #require(bridge.sessions.first?.busySince)
        let dispatched = try #require(recap(of: bridge.sessions.first)?.answeredAt)

        // 停止只停指挥官自己这一轮（Esc 的同一能力）：指挥官已歇下，停止成功但不动子代理，会话仍在等子代理
        try await bridge.abort(try #require(bridge.sessions.first?.id))
        #expect(bridge.sessions.first?.state == .delegating)
        gate.openForever()  // 子代理停在假模型里，到这里才让它做完

        try await eventually("指挥官回应了子代理事件") {
            recap(of: bridge.sessions.first)?.lastReply?.contains("firecode_master_event") == true
        }
        #expect(recap(of: bridge.sessions.first)?.lastPrompt == "派个子代理")
        try await eventually("全部歇下") { bridge.sessions.first?.state == .settled }
        // 歇下就绪（`PiSessionState.answered`）：派活那一轮的收尾早于交回结果那一轮的开始，那一轮的收尾不早于它
        let turn = try #require(bridge.sessions.first?.turnStartedAt)
        let answered = try #require(recap(of: bridge.sessions.first)?.answeredAt)
        #expect(dispatched < turn && turn <= answered, "\(dispatched) \(turn) \(answered)")
        #expect(bridge.sessions.first?.busySince == nil)
        let done = try #require(bridge.sessions.first?.subagents.first)
        #expect(done.phase == .known(.done) && !done.action.isEmpty)
        #expect(try #require(done.settledAt) >= #require(done.startedAt))
        // 名册里它这一项变了，Mac 就记下这一刻有进展（等子代理太久没动静的兜底读它）
        #expect(try #require(done.progressAt) > #require(ui.progressAt))
        let busy = log.changes.compactMap { change -> Date? in
            guard case .stateChanged(let session, _) = change else { return nil }
            return session.busySince
        }
        #expect(busy.allSatisfy { $0 == start }, "从派活到全部歇下只有一段连续处理")
        #expect(bridge.sessions.count == 1)
        try await eventually("日志记下了") { log.changes.filter { if case .appeared = $0 { true } else { false } }.count == 1 }
    }

    @Test func aHostedMasterOutlivesAKilledSubagentWhileAnotherIsStillRunning() async throws {
        let idleSeconds = 1
        let pi = try await PiProcess(extraExtensions: [], firecode: true, env: ["CUEPAD_HOSTED": "\(idleSeconds)"])
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        // 托管的 Pi 一起来就开始算空闲：第一句话经它自己的标准输入马上交出，不等桥发现它（同一测试进程忙时，发现会晚过这 1 秒，它已经退了）
        var gate = script(pi, "派 a", "start", worker: "a")
        try pi.prompt("派 a")
        try await eventually("桥发现指挥官会话") { !bridge.sessions.isEmpty }
        let id = bridge.sessions[0].id
        func delegating(after prompt: String) -> Bool {
            let session = bridge.session(id: id)
            return session?.state == .delegating && recap(of: session)?.lastPrompt == prompt
        }
        try await eventually("子代理 a 在跑（停在假模型里）") { delegating(after: "派 a") }
        gate = script(pi, "派 b", "start", worker: "b")
        try pi.prompt("派 b")
        try await eventually("子代理 b 在跑（停在假模型里）") { delegating(after: "派 b") }
        try pi.requireSubagentsTool()
        _ = script(pi, "移除 a", "kill", worker: "a")
        try pi.prompt("移除 a")
        try await eventually("a 被移除，b 还在跑") { delegating(after: "移除 a") && bridge.session(id: id)?.subagents.map(\.name) == ["b"] }

        await quietPeriod(.seconds(idleSeconds * 3))  // 等过几个空闲时限
        try #require(bridge.session(id: id)?.state == .delegating, "b 还在跑，托管进程不该到点退出")

        gate.openForever()  // b 做完，结果投回指挥官
        try await eventually("全部做完后到点退出") { bridge.session(id: id) == nil }
    }
}
#endif
