#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CuePi

@MainActor
@Suite(RealAgents.taped(.pi), .agentTape(.pi), RealAgents.serialWhenRecording(.pi), RealAgents.timeLimit(.minutes(2)))
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
        try pi.prompt("<some_event>\n子任务完成\n</some_event>")
        try await eventually("机器消息那轮落盘") { try roundsDone(file, 3) }

        let update = try PiHistory.index(file: file, from: nil)
        let messages = update.messages
        #expect(messages.map(\.role.known) == [.user, .pi, .user, .pi, .machine, .pi])
        #expect(messages.map(\.text).prefix(4) == ["第一问", "ECHO 第一问 IMAGES[]", "[[tool:echo TOOL-OUTPUT-42]]", "TOOL_DONE"])
        #expect(!messages.contains { $0.text.contains("TOOL-OUTPUT-42\n") || $0.text == "TOOL-OUTPUT-42" })  // 工具输出不进对话
        #expect(messages.map { $0.tools?.steps } == [nil, nil, nil, 1, nil, nil])
        #expect(messages[3].roundStartedAt.map { $0 <= messages[3].at } == true)
        #expect(messages.map(\.seq) == messages.map(\.seq).sorted() && Set(messages.map(\.seq)).count == 6)
        #expect(update.recap.lastPrompt == "[[tool:echo TOOL-OUTPUT-42]]" && update.recap.lastReply?.contains("子任务完成") == true)
        #expect(update.recap.pendingPrompt == nil)

        try pi.prompt("第三问")
        try await eventually("第三轮落盘") { try roundsDone(file, 4) }
        let next = try PiHistory.index(file: file, from: update.checkpoint)
        #expect(next.messages.map(\.text) == ["第三问", "ECHO 第三问 IMAGES[]"])
        #expect(next.recap.lastPrompt == "第三问")
    }

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
        #expect(tools.map { $0?.items.map(\.kind) } == [[.command], [.edit], [.command]])
        #expect(tools[1]?.items.first?.target == "out.txt" && tools.map { $0?.items.map(\.failed) } == [[false], [false], [true]])
    }
}
#endif
