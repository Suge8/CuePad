#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 不用模型，只要 Claude Code 的测试台与它报的版本。
@MainActor
@Suite(RealAgents.needs(.claudeCode))
struct ClaudeSettingsTests {
    @Test(arguments: [nil, RealClaudeTerminalTests.userSettings, #"{"hooks":{"Stop":[]},"theme":"dark"}"#])
    func connectingAndDisconnectingLeavesTheUsersSettingsByteForByte(settings: String?) async throws {
        try await ClaudeTestbed.run(installHooks: false, settings: settings) { testbed in
            let file = testbed.config.appending(path: "settings.json")
            let moved = AgentIntegration(
                paths: testbed.paths, locate: { pinnedClaude.locator },
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

    /// `Fixtures/grok-claude-hooks.jsonl` 是 Grok Build 一场会话里真发的输入，环境照它给的。
    @Test func anotherAgentRunningTheseHooksIsLetThroughAndNotTakenForAClaudeCodeSession() async throws {
        let inputs = try String(contentsOf: fixturesDirectory.appending(path: "grok-claude-hooks.jsonl"), encoding: .utf8).split(separator: "\n")
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
