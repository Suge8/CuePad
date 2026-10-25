#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 接入（装钩子）与关掉接入（删钩子）只动 settings.json 里 CuePad 的条目：不起 Claude Code，只要它的测试台（录像带是空的）。
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
}
#endif
