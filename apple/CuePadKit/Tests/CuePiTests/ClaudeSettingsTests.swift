#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// CuePad 装进 settings.json 的钩子：接入与关掉接入只动 CuePad 的条目；别家照读这份配置跑这些钩子时 CuePad 不把它当成 Claude Code 会话。
/// 不起 Claude Code，只要它的测试台（录像带是空的）。
@MainActor
@Suite(RealAgents.taped(.claudeCode), .agentTape(.claudeCode), RealAgents.timeLimit(.minutes(5)))
struct ClaudeSettingsTests {
    /// 接入只把 CuePad 的钩子合并进用户自己的 settings.json；关掉接入（中间 App 搬过家、升级过也一样）后与装之前逐字节一致：
    /// 原来没有文件就没有文件，原来空着的事件数组原样留着。
    @Test(arguments: [nil, RealClaudeTerminalTests.userSettings, #"{"hooks":{"Stop":[]},"theme":"dark"}"#])
    func connectingAndDisconnectingLeavesTheUsersSettingsByteForByte(settings: String?) async throws {
        AgentTape.variant(settings.map { "\($0.count)" } ?? "none")
        try await ClaudeTestbed.run(installHooks: false, settings: settings) { testbed in
            let file = testbed.config.appending(path: "settings.json")
            let moved = AgentIntegration(
                paths: testbed.paths, locate: { AgentTape.locator("claude") },
                cuepad: testbed.root.appending(path: "Moved/CuePad.app/Contents/Helpers/cuepad"), timing: noDeadline)

            try await testbed.integration.install(.claudeCode)
            #expect(await testbed.integration.status(of: .claudeCode).files == .current)
            try await moved.install(.claudeCode)
            #expect(await moved.status(of: .claudeCode).files == .current)
            try await moved.uninstall(.claudeCode)

            #expect((try? String(contentsOf: file, encoding: .utf8)) == settings)
            #expect(await moved.status(of: .claudeCode).files == .missing)
        }
    }

    /// Grok Build 照读 `~/.claude/settings.json` 跑 CuePad 装的钩子（`Fixtures/grok-claude-hooks.jsonl` 是它一场会话里真发的输入，
    /// 环境照它给的）：每次都原样放行（不输出、退出码 0，提问与确认不被挂住），桥上不多出会话。
    @Test func anotherAgentRunningTheseHooksIsLetThroughAndNotTakenForAClaudeCodeSession() async throws {
        let inputs = try String(contentsOf: fixturesDirectory.appending(path: "grok-claude-hooks.jsonl"), encoding: .utf8).split(separator: "\n")
        // CuePad 接上已在跑的会话时问的 `claude agents`：没有
        try await ClaudeTestbed.run(installHooks: false, wrapper: #"if [ "$1" = agents ]; then echo '[]'; else "$REAL" "$@"; fi"#) { testbed in
            try testbed.startConnected()
            for (index, input) in inputs.enumerated() {
                let fields = try #require(JSONValue.parse(Data(input.utf8)))
                let file = testbed.root.appending(path: "grok-hook-\(index).json")
                try Data(input.utf8).write(to: file)
                let environment = [
                    "PATH": "/usr/bin:/bin", "HOME": testbed.root.appending(path: "home").path, "CUEPAD_PI_SOCKET_DIR": testbed.sockets.path,
                    "CLAUDE_PROJECT_DIR": testbed.work.path, "GROK_SESSION_ID": fields["sessionId"]?.string ?? "",
                    "GROK_HOOK_EVENT": fields["hookEventName"]?.string ?? "", "GROK_WORKSPACE_ROOT": testbed.work.path,
                ]
                // exec：钩子的父进程是一直在的测试进程，像 Grok 那样（CuePad 认父进程为 Agent，它退出时会话下桥）
                let run = await ChildProcess.run(
                    URL(filePath: "/bin/sh"), ["-c", #"exec "$0" hook claude < "$1""#, PiProcess.cuepad.path, file.path],
                    environment: environment, timeout: conditionBudget)
                #expect(run?.status == 0 && run?.output == "", "\(fields["hook_event_name"]?.string ?? "?") 没有原样放行：\(String(describing: run))")
            }
            #expect(testbed.bridge.sessions.isEmpty)
        }
    }
}
#endif
