#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 大脑的生死，经公开入口 `startBrain()`，运行时是假脚本（不花钱、默认跑）。脚本把自己的 pid 写进 `$PID_FILE`，
/// 用来确认进程真的没了。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BrainLifecycleTests {
    private func fakeRuntime(_ runtime: AgentKind, _ body: String) throws -> (CueBrainConfig, pid: URL) {
        let directory = try makeTempDirectory()
        let script = directory.appending(path: "fake-\(runtime.rawValue)")
        try "#!/bin/sh\necho $$ > \"$PID_FILE\"\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let pid = directory.appending(path: "pid")
        let config = CueBrainConfig(
            runtime: runtime, executable: script, systemPrompt: "x", workingDirectory: directory, mcp: ["/usr/bin/true"],
            environment: ["PID_FILE": pid.path])
        return (config, pid)
    }

    private func pid(in file: URL) throws -> pid_t {
        try #require(pid_t(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// 运行时一开口（初始化）就拒绝、之后也不退出、还忽略 SIGTERM：启动照样返回、抛出它的拒绝原文，起了的进程不留下
    /// （调用方拿不到大脑，没人能收拾）。
    @Test func aRuntimeThatRejectsTheHandshakeIsNotLeftRunning() async throws {
        let (config, file) = try fakeRuntime(.codex, #"""
            trap '' TERM
            read line
            id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
            printf '{"id":%s,"error":{"code":-1,"message":"nope"}}\n' "$id"
            exec sleep 300
            """#)
        await #expect(throws: CodexRPCError.server(code: -1, message: "nope")) { _ = try await config.startBrain() }
        #expect(kill(try pid(in: file), 0) != 0)
    }

    /// 运行时不理会输入关闭、也忽略 SIGTERM：stop() 在两个宽限期后结束整个进程组，报告退出。
    @Test func stopEndsARuntimeThatIgnoresEOFAndSIGTERM() async throws {
        let (config, file) = try fakeRuntime(.claudeCode, "trap '' TERM\nexec sleep 300")
        let brain = try await config.startBrain()
        do {
            // 脚本跑起来写下 pid 之前停它，测不到"忽略 SIGTERM"
            try await eventually("假运行时写下 pid", timeout: .seconds(5)) { (try? pid(in: file)) != nil }
        } catch {
            await brain.stop()()
            throw error
        }
        await brain.stop()()
        #expect(kill(try pid(in: file), 0) != 0)
        var last: CueBrainEvent?
        for await event in brain.events { last = event }
        #expect(last == .exited(nil))
    }
}
#endif
