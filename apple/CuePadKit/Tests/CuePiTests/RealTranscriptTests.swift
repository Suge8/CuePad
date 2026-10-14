#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CuePi

/// 端到端：会话的对话从 Pi 的会话文件读出——一轮一条 Pi 消息（只取最后的回答，工具只成摘要），你的消息带着
/// CuePad 送进去时的投送请求 id；会话记录上的摘要是对话的投影。
@MainActor
@Suite(.enabled(if: realPiAvailable, RealAgents.skipped(.pi, needs: "~/.local/bin/pi")), .timeLimit(.minutes(2)))
struct RealTranscriptTests {
    private func rig() async throws -> (PiProcess, PiBridge, URL) {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        try bridge.start()
        try await eventually("桥发现会话") { !bridge.sessions.isEmpty }
        return (pi, bridge, try #require(bridge.sessions.first?.sessionFile))
    }

    private func roundsDone(_ file: URL, _ count: Int) throws -> Bool {
        (try? PiHistory.index(file: file, from: nil))?.messages.filter { $0.role == .known(.pi) }.count == count
    }

    @Test func multipleRoundsBecomeOrderedMessagesWithToolsOnlyAsASummary() async throws {
        let (pi, bridge, file) = try await rig()
        defer { bridge.stop(); pi.stop() }

        try pi.prompt("第一问")
        try await eventually("第一轮落盘") { try roundsDone(file, 1) }
        try pi.prompt("[[tool:echo TOOL-OUTPUT-42]]")
        try await eventually("工具轮落盘") { try roundsDone(file, 2) }
        // 机器消息（扩展投进来的信封）不算你说的；它触发的那轮回答照常是一条 Pi 消息
        try pi.prompt("<some_event>\n子任务完成\n</some_event>")
        try await eventually("机器消息那轮落盘") { try roundsDone(file, 3) }

        let update = try PiHistory.index(file: file, from: nil)
        let messages = update.messages
        #expect(messages.map(\.role.known) == [.user, .pi, .user, .pi, .pi])
        #expect(messages.map(\.text).prefix(4) == ["第一问", "ECHO 第一问 IMAGES[]", "[[tool:echo TOOL-OUTPUT-42]]", "TOOL_DONE"])
        #expect(!messages.contains { $0.text.contains("TOOL-OUTPUT-42\n") || $0.text == "TOOL-OUTPUT-42" })  // 工具输出不进对话
        #expect(messages.map { $0.tools?.commands } == [nil, nil, nil, 1, nil])
        #expect(messages[3].roundStartedAt.map { $0 <= messages[3].at } == true)
        #expect(messages.map(\.seq) == messages.map(\.seq).sorted() && Set(messages.map(\.seq)).count == 5)
        // 摘要：最近一轮做完的问答（机器消息那轮沿用你说的那句），没有进行中的提问
        #expect(update.recap.lastPrompt == "[[tool:echo TOOL-OUTPUT-42]]" && update.recap.lastReply?.contains("子任务完成") == true)
        #expect(update.recap.pendingPrompt == nil)

        // 增量读：从检查点继续只给出新消息
        try pi.prompt("第三问")
        try await eventually("第三轮落盘") { try roundsDone(file, 4) }
        let next = try PiHistory.index(file: file, from: update.checkpoint)
        #expect(next.messages.map(\.text) == ["第三问", "ECHO 第三问 IMAGES[]"])
        #expect(next.recap.lastPrompt == "第三问")
    }

    /// 真实 Pi 写出的工具结果行（键序、isError）决定摘要读不读得到失败：跑一条成功的命令、写一个文件、再跑一条退出码非 0 的命令。
    @Test func realToolResultsDecideWhichCallsFailed() async throws {
        let (pi, bridge, file) = try await rig()
        defer { bridge.stop(); pi.stop() }

        try pi.prompt("[[tool:echo ok]]")
        try await eventually("成功的一轮落盘") { try roundsDone(file, 1) }
        try pi.prompt("[[write:out.txt]]")
        try await eventually("写文件的一轮落盘") { try roundsDone(file, 2) }
        try pi.prompt("[[tool:false]]")
        try await eventually("失败的一轮落盘") { try roundsDone(file, 3) }

        let tools = try PiHistory.index(file: file, from: nil).messages.filter { $0.role == .known(.pi) }.map(\.tools)
        #expect(tools.map { $0?.commands } == [1, 0, 1] && tools.map { $0?.edits } == [0, 1, 0])
        #expect(tools[1]?.items.first?.target == "out.txt" && tools.map { $0?.items.map(\.failed) } == [[false], [false], [true]])
    }

    @Test func aPromptStillRunningIsPendingInTheRecap() async throws {
        let (pi, bridge, file) = try await rig()
        defer { bridge.stop(); pi.stop() }

        try pi.prompt("[[slow]] 慢慢来")
        try await eventually("你的消息落盘") {
            (try? PiHistory.index(file: file, from: nil))?.messages.first?.role == .known(.user)
        }
        let update = try PiHistory.index(file: file, from: nil)
        #expect(update.recap.pendingPrompt == "[[slow]] 慢慢来" && update.recap.lastReply == nil)
    }

    /// CuePad 送进去的消息带着投送请求 id：扩展写进会话文件里那条你的消息，对话据此把请求气泡换成这条消息。
    @Test func aMessageSentThroughCuePadCarriesItsDeliveryID() async throws {
        let (pi, bridge, file) = try await rig()
        defer { bridge.stop(); pi.stop() }
        let session = try #require(bridge.sessions.first)

        let delivery = UUID()
        _ = try await bridge.send(PiMessage(text: "从手机发的", deliveryID: delivery.uuidString), to: session.id)
        try await eventually("那一轮落盘") { try roundsDone(file, 1) }
        try pi.prompt("终端里打的")
        try await eventually("第二轮落盘") { try roundsDone(file, 2) }

        let users = try PiHistory.index(file: file, from: nil).messages.filter { $0.role == .known(.user) }
        #expect(users.map(\.text) == ["从手机发的", "终端里打的"])
        #expect(users.map(\.deliveryID) == [delivery, nil])
    }
}
#endif
