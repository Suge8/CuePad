#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// "发给手机看"的端到端：真实 Pi + 安装器装进临时目录的扩展与 skill + 假模型 + 真实的 `cuepad` 命令行。
/// 模型在 bash 里执行 `cuepad show`：Pi 给这条命令带着 `PI_SESSION_ID`，命令行据此认出会话、把预览写进（隔离的）资料库。
@MainActor
@Suite(RealAgents.taped(.pi), .agentTape(.pi), RealAgents.serialWhenRecording(.pi))
struct RealPreviewTests {
    private func sqlite(_ database: URL, _ query: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = [database.path, query]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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

        try pi.prompt("[[tool:\(PiProcess.cuepad.path) show demo.html --title 登录页改好了 --json]] 给我看看")
        _ = try await pi.waitForEvent("命令结束", { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "bash" })
        _ = try await pi.waitForEvent("这一轮结束", { $0["type"] as? String == "agent_end" })

        let result = try bashResult(pi)
        #expect(!result.isError)
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        #expect(reply["session"] as? String == session.sessionID && reply["title"] as? String == "登录页改好了" && reply["name"] as? String == "demo.html")
        #expect(try sqlite(library.appending(path: "cuepad.db"), "SELECT sessionID || '|' || title FROM previews") == "\(session.sessionID)|登录页改好了")
    }

    /// 不在 Pi 的 bash 里（没有 PI_SESSION_ID）时命令失败并说明，不猜是哪个会话。
    @Test func outsidePiTheCommandRefusesAndNothingIsStored() async throws {
        let library = try makeTempDirectory()
        let page = library.appending(path: "demo.html")
        try "<h1>x</h1>".write(to: page, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = PiProcess.cuepad
        process.arguments = ["show", page.path]
        process.environment = ["CUEPAD_LIBRARY_DIR": library.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus != 0)
        #expect(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("PI_SESSION_ID"))
        #expect(try sqlite(library.appending(path: "cuepad.db"), "SELECT count(*) FROM previews") == "0")
    }
}
#endif
