#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 端到端：真实 Pi + 本机 FireCode（指挥官开进程内子代理、把子代理事件以信封投回会话）+ 桥扩展 + 假模型。
@MainActor
@Suite(.enabled(if: realPiAvailable && firecodeAvailable, "需要 ~/.local/bin/pi 与 ~/.pi/agent/extensions/firecode"))
struct RealFirecodeTests {
    @Test func subagentsAreSummarizedOnTheMasterSessionAndTheirEventsAreNotYourPrompt() async throws {
        let pi = try await PiProcess(extraExtensions: [], firecode: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let log = ChangeLog(bridge)
        try await eventually("桥发现指挥官会话", timeout: .seconds(20)) { !bridge.sessions.isEmpty }

        try pi.prompt("[[subagent:ui]]")
        try await eventually("子代理出现在指挥官会话的摘要里（或 subagents 工具报错）", timeout: .seconds(20)) {
            bridge.sessions.first?.subagents.map(\.name) == ["ui"] || pi.subagentsToolFailed
        }
        try pi.requireSubagentsTool()  // 指挥官没加载时立即带 FireCode 的提示原文失败
        // 角色与本次运行的开始来自 FireCode 的子代理名册
        let ui = try #require(bridge.sessions.first?.subagents.first)
        #expect(ui.role == "工程师" && ui.startedAt != nil)

        // 指挥官自己这轮已经答完，子代理还在跑：仍是工作中，计时从派活那轮开始不重置
        try await eventually("指挥官歇下、等子代理", timeout: .seconds(20)) {
            recap(of: bridge.sessions.first)?.lastReply == "TOOL_DONE" && bridge.sessions.first?.state == .delegating
        }
        let start = try #require(bridge.sessions.first?.busySince)

        // 停止只停指挥官自己这一轮（Esc 的同一能力）：指挥官已歇下，停止成功但不动子代理，会话仍在等子代理
        try await bridge.abort(try #require(bridge.sessions.first?.id))
        #expect(bridge.sessions.first?.state == .delegating)

        // 子代理停下后 FireCode 把事件信封作为用户消息投回：指挥官对它的回应照常是最终回答，提问不变
        try await eventually("指挥官回应了子代理事件", timeout: .seconds(30)) {
            recap(of: bridge.sessions.first)?.lastReply?.contains("firecode_master_event") == true
        }
        #expect(recap(of: bridge.sessions.first)?.lastPrompt == "[[subagent:ui]]")
        // 子代理结束、事件交给指挥官、指挥官回应完才歇下：中间计时一直是同一段
        try await eventually("全部歇下", timeout: .seconds(20)) { bridge.sessions.first?.state == .settled }
        #expect(bridge.sessions.first?.busySince == nil)
        // 子代理做完交回：状态停在"已交回"，带落定时刻与结果首句
        let done = try #require(bridge.sessions.first?.subagents.first)
        #expect(done.phase == .known(.done) && !done.action.isEmpty)
        #expect(try #require(done.settledAt) >= #require(done.startedAt))
        let busy = log.changes.compactMap { change -> Date? in
            guard case .stateChanged(let session, _) = change else { return nil }
            return session.busySince
        }
        #expect(busy.allSatisfy { $0 == start }, "从派活到全部歇下只有一段连续处理")
        // 进程内子会话不作为独立会话出现
        #expect(bridge.sessions.count == 1)
        #expect(log.changes.filter { if case .appeared = $0 { true } else { false } }.count == 1)
    }
}
#endif
