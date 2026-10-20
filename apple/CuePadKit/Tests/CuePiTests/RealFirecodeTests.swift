#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：真实 Pi + 本机 FireCode（指挥官开进程内子代理、把子代理事件以信封投回会话）+ 桥扩展 + 假模型。
@MainActor
@Suite(RealAgents.taped(.pi), .enabled(if: RealAgents.mode(of: .pi) == .replay || firecodeAvailable, "录制要本机的 FireCode 源码"), .agentTape(.pi), RealAgents.serialWhenRecording(.pi), RealAgents.timeLimit(.minutes(5)))
struct RealFirecodeTests {
    @Test func subagentsAreSummarizedOnTheMasterSessionAndTheirEventsAreNotYourPrompt() async throws {
        let pi = try await PiProcess(extraExtensions: [], firecode: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let log = ChangeLog(bridge)
        try await eventually("桥发现指挥官会话") { !bridge.sessions.isEmpty }

        try pi.prompt("[[subagent:ui]]")
        try await eventually("子代理出现在指挥官会话的摘要里（或 subagents 工具报错）") {
            bridge.sessions.first?.subagents.map(\.name) == ["ui"] || pi.subagentsToolFailed
        }
        try pi.requireSubagentsTool()  // 指挥官没加载时立即带 FireCode 的提示原文失败
        // 角色、模型与本次运行的开始来自 FireCode 的子代理名册
        let ui = try #require(bridge.sessions.first?.subagents.first)
        #expect(ui.role == "工程师" && ui.startedAt != nil && ui.model?.contains("/") == true)

        // 指挥官自己这轮已经答完，子代理还在跑：仍是工作中，计时从派活那轮开始不重置
        try await eventually("指挥官歇下、等子代理") {
            recap(of: bridge.sessions.first)?.lastReply == "TOOL_DONE" && bridge.sessions.first?.state == .delegating
        }
        let start = try #require(bridge.sessions.first?.busySince)
        let dispatched = try #require(recap(of: bridge.sessions.first)?.answeredAt)

        // 停止只停指挥官自己这一轮（Esc 的同一能力）：指挥官已歇下，停止成功但不动子代理，会话仍在等子代理
        try await bridge.abort(try #require(bridge.sessions.first?.id))
        #expect(bridge.sessions.first?.state == .delegating)
        let releasing = pi.releaseEveryHold()  // 子代理停在假模型里，到这里才让它做完；它的结果带着标记，指挥官回应时也会停住
        defer { releasing.cancel() }

        // 子代理停下后 FireCode 把事件信封作为用户消息投回：指挥官对它的回应照常是最终回答，提问不变
        try await eventually("指挥官回应了子代理事件") {
            recap(of: bridge.sessions.first)?.lastReply?.contains("firecode_master_event") == true
        }
        #expect(recap(of: bridge.sessions.first)?.lastPrompt == "[[subagent:ui]]")
        // 子代理结束、事件交给指挥官、指挥官回应完才歇下：中间计时一直是同一段
        try await eventually("全部歇下") { bridge.sessions.first?.state == .settled }
        // 歇下就绪（`PiSessionState.answered`）：派活那一轮的收尾早于交回结果那一轮的开始，那一轮的收尾不早于它
        let turn = try #require(bridge.sessions.first?.turnStartedAt)
        let answered = try #require(recap(of: bridge.sessions.first)?.answeredAt)
        #expect(dispatched < turn && turn <= answered, "\(dispatched) \(turn) \(answered)")
        #expect(bridge.sessions.first?.busySince == nil)
        // 子代理做完交回：状态停在"已交回"，带落定时刻与结果首句
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
        // 进程内子会话不作为独立会话出现
        #expect(bridge.sessions.count == 1)
        try await eventually("日志记下了") { log.changes.filter { if case .appeared = $0 { true } else { false } }.count == 1 }
    }

    /// CuePad 后台托管的指挥官（`CUEPAD_HOSTED`）只在自己这一轮做完、子代理也都歇下时才算空闲：子代理的会话歇下或被移除都不算。
    /// 移除一个在跑的子代理、另一个还在跑时，进程不能到点自己退出；全部做完照常到点退出。
    @Test func aHostedMasterOutlivesAKilledSubagentWhileAnotherIsStillRunning() async throws {
        let idleSeconds = 1
        let pi = try await PiProcess(extraExtensions: [], firecode: true, env: ["CUEPAD_HOSTED": "\(idleSeconds)"])
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现指挥官会话") { !bridge.sessions.isEmpty }
        let id = bridge.sessions[0].id
        /// 指挥官这一轮做完（说的就是 `prompt`）、在等子代理
        func delegating(after prompt: String) -> Bool {
            let session = bridge.session(id: id)
            return session?.state == .delegating && recap(of: session)?.lastPrompt == prompt
        }

        for name in ["a", "b"] {
            try pi.prompt("[[subagent:\(name)]]")
            try await eventually("子代理 \(name) 在跑（停在假模型里）") { delegating(after: "[[subagent:\(name)]]") }
        }
        try pi.requireSubagentsTool()
        try pi.prompt("[[kill:a]]")
        try await eventually("a 被移除，b 还在跑") { delegating(after: "[[kill:a]]") && bridge.session(id: id)?.subagents.map(\.name) == ["b"] }

        // 等过几个空闲时限（回放时空闲的时长不占时间：之后的输出由放行的标记排先后）
        if AgentTape.active.mode == .record { await quietPeriod(.seconds(idleSeconds * 3)) }
        try #require(bridge.session(id: id)?.state == .delegating, "b 还在跑，托管进程不该到点退出")

        let releasing = pi.releaseEveryHold()  // b 做完，结果投回指挥官；回应里带着假模型的停住标记，同样放行
        defer { releasing.cancel() }
        try await eventually("全部做完后到点退出") { bridge.session(id: id) == nil }
    }
}
#endif
