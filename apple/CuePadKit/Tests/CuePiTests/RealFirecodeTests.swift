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
        try await eventually("子代理出现在指挥官会话的摘要里", timeout: .seconds(20)) {
            bridge.sessions.first?.subagents.map(\.name) == ["ui"]
        }
        #expect(bridge.sessions.first?.subagentSummary?.contains("ui") == true)

        // 子代理停下后 FireCode 把事件信封作为用户消息投回：指挥官对它的回应照常是最终回答，提问不变
        try await eventually("指挥官回应了子代理事件", timeout: .seconds(30)) {
            bridge.sessions.first?.lastReply?.contains("firecode_master_event") == true
        }
        #expect(bridge.sessions.first?.lastPrompt == "[[subagent:ui]]")
        // 进程内子会话不作为独立会话出现
        #expect(bridge.sessions.count == 1)
        #expect(log.changes.filter { if case .appeared = $0 { true } else { false } }.count == 1)
    }
}
#endif
