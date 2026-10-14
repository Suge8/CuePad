#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// "发给手机看"的端到端：真实 Pi + 安装器装进临时目录的扩展与 skill + 假模型 + 真实的 `cuepad` 命令行。
/// 模型在 bash 里一次 `cuepad show` 两个文件：Pi 给这条命令带着 `PI_SESSION_ID`，命令行据此认出会话、把预览写进（隔离的）资料库。
@MainActor
@Suite(RealAgents.taped(.pi), .agentTape(.pi), RealAgents.serialWhenRecording(.pi), RealAgents.timeLimit(.minutes(5)))
struct RealPreviewTests {
    private func sqlite(_ database: URL, _ query: String) async throws -> String {
        try #require(await runCapturing(URL(filePath: "/usr/bin/sqlite3"), [database.path, query])).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bashResult(_ pi: PiProcess) throws -> (isError: Bool, text: String) {
        let event = try #require(pi.events.last { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "bash" })
        let blocks = (event["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return (event["isError"] as? Bool == true, blocks.compactMap { $0["text"] as? String }.joined())
    }

    @Test func theSkillIsDiscoveredAndShowFromBashAttachesThePreviewToTheSession() async throws {
        let library = try makeTempDirectory()
        AgentTape.active.watch(library)  // 预览是 Pi 的 bash 里跑的 cuepad 命令写进资料库的
        let pi = try await PiProcess(env: ["CUEPAD_LIBRARY_DIR": library.path], discoverSkills: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        let session = bridge.sessions[0]
        // Pi 从它的 skills 目录发现了安装器写的 skill
        let skill = try #require(session.commands.first { $0.name == "skill:cuepad" })
        #expect(skill.source == .known(.skill) && skill.summary?.contains("CuePad") == true)
        try "<h1>登录页</h1>".write(to: pi.cwd.appending(path: "demo.html"), atomically: true, encoding: .utf8)
        try Data("m4a".utf8).write(to: pi.cwd.appending(path: "beep.m4a"))

        try pi.prompt("[[tool:\(PiProcess.cuepad.path) show demo.html beep.m4a --title 登录页改好了 --json]] 给我看看")
        _ = try await pi.waitForEvent("命令结束", { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "bash" })
        _ = try await pi.waitForEvent("这一轮结束", { $0["type"] as? String == "agent_end" })

        let result = try bashResult(pi)
        #expect(!result.isError, "\(result.text)")
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [[String: Any]])
        #expect(reply.map { $0["name"] as? String } == ["demo.html", "beep.m4a"])
        #expect(reply.allSatisfy { $0["session"] as? String == session.sessionID && $0["title"] as? String == "登录页改好了" })
        // 一次发的两个是同一批：同一创建时间
        #expect(try await sqlite(library.appending(path: "cuepad.db"), "SELECT count(DISTINCT createdAt) || '|' || count(*) FROM previews WHERE sessionID = '\(session.sessionID)'") == "1|2")
    }

    /// 不在 Pi 的 bash 里（没有 PI_SESSION_ID）时命令失败并说明，不猜是哪个会话。
    @Test func outsidePiTheCommandRefusesAndNothingIsStored() async throws {
        let library = try makeTempDirectory()
        let page = library.appending(path: "demo.html")
        try "<h1>x</h1>".write(to: page, atomically: true, encoding: .utf8)
        // 报错在标准错误里：经 sh 并进标准输出
        let shown = try #require(await runCapturing(
            URL(filePath: "/bin/sh"), ["-c", "exec \"$0\" show \"$1\" 2>&1", PiProcess.cuepad.path, page.path],
            environment: ["CUEPAD_LIBRARY_DIR": library.path]))
        #expect(shown.status != 0)
        #expect(shown.output.contains("PI_SESSION_ID"))
        #expect(try await sqlite(library.appending(path: "cuepad.db"), "SELECT count(*) FROM previews") == "0")
    }
}
#endif
