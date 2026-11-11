#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

/// 模型在 bash 里一次 `cuepad show` 两个文件：这条命令带着会话的环境变量（扩展设的 `CUEPAD_SESSION_ID` 在先，Pi 自己的 `PI_SESSION_ID`），
/// 命令行据此认出会话、把预览写进（隔离的）资料库。
@MainActor
@Suite(RealAgents.needs(.pi), RealAgents.tiered)
struct RealPreviewTests {
    private func bashResult(_ pi: PiProcess) throws -> (isError: Bool, text: String) {
        let event = try #require(pi.events.last { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "bash" })
        let blocks = (event["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return (event["isError"] as? Bool == true, blocks.compactMap { $0["text"] as? String }.joined())
    }

    @Test func theSkillIsDiscoveredAndShowFromBashAttachesThePreviewToTheSession() async throws {
        let library = try makeTempDirectory()
        let pi = try await PiProcess(env: ["CUEPAD_LIBRARY_DIR": library.path], discoverSkills: true)
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        let session = bridge.sessions[0]
        let skill = try #require(session.commands.first { $0.name == "skill:cuepad" })
        #expect(skill.source == .known(.skill) && skill.summary?.contains("CuePad") == true)
        try "<h1>登录页</h1>".write(to: pi.cwd.appending(path: "demo.html"), atomically: true, encoding: .utf8)
        try Data("m4a".utf8).write(to: pi.cwd.appending(path: "beep.m4a"))

        pi.model.on("给我看看", .call("bash", ["command": "\(PiProcess.cuepad.path) show demo.html beep.m4a --title 登录页改好了 --title 提示音 --json"]), .say("TOOL_DONE"))
        try pi.prompt("给我看看")
        _ = try await pi.waitForEvent("命令结束", { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "bash" })
        _ = try await pi.waitForEvent("这一轮结束", { $0["type"] as? String == "agent_end" })

        let result = try bashResult(pi)
        #expect(!result.isError, "\(result.text)")
        // 存了什么、同一批是 CLI 自己的事（CueCLITests）：这里只看 Pi 交给命令的会话 id 认对了
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: Any]])
        #expect(reply.count == 2 && reply.allSatisfy { $0["session"] as? String == session.sessionID })
    }
}
#endif
