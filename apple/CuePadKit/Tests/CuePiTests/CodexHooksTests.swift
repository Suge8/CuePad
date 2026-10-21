#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePi

/// 接入 Codex 的钩子，用真 codex 判定（它自己的 `hooks/list` 说信任了才算装好）。
@MainActor
@Suite(RealAgents.taped(.codex), .agentTape(.codex), RealAgents.timeLimit(.minutes(2)))
struct CodexHooksTests {
    let codex: CodexHome
    /// 钩子命令里的 cuepad 只是字符串（这里不跑钩子）。用固定路径：Codex 的信任哈希按命令算，录下的哈希回放时要对得上
    let cuepad = URL(filePath: "/Applications/CuePad.app/Contents/Helpers/cuepad")
    var command: String { "\(cuepad.path) hook codex" }
    var hooksFile: URL { codex.home.appending(path: "hooks.json") }
    var configFile: URL { codex.home.appending(path: "config.toml") }

    init() throws { codex = try CodexHome() }

    private func integration(cuepad: URL? = nil) -> AgentIntegration {
        AgentIntegration(paths: codex.paths, locate: { [codex] in codex.locator }, cuepad: cuepad ?? self.cuepad)
    }

    /// 用户自己的钩子（格式随手写）已被信任；接入后 CuePad 的 10 个事件都被 Codex 信任、用户的照旧；
    /// App 挪了位置是旧版、重装又是新的；关掉后 hooks.json 与 config.toml 和接入之前逐字节一致。
    @Test func installIsTrustedByCodexAndUninstallRestoresTheUsersFilesExactly() async throws {
        try await codex.using {
            let userHooks = """
                {
                  "description": "我的钩子",
                  "hooks": {
                    "SessionStart": [ { "hooks": [ { "type": "command", "command": "echo hi", "timeout": 5 } ] } ],
                    "Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo bye"}]}]
                  }
                }

                """
            try userHooks.write(to: hooksFile, atomically: true, encoding: .utf8)
            try "model = \"gpt-6-luna\"  # 我的模型\n\n[tui]\nanimations = false\n".write(to: configFile, atomically: true, encoding: .utf8)
            try await codex.trustEverything()
            let before = (try Data(contentsOf: hooksFile), try Data(contentsOf: configFile))

            try await integration().install(.codex)

            #expect(await integration().status(of: .codex).files == .current)
            var hooks = try await codex.hookTrust()
            #expect(hooks.filter { $0.command == command }.count == 10)
            #expect(hooks.filter { $0.command == command }.allSatisfy { $0.trust == "trusted" })
            #expect(hooks.filter { $0.command.hasPrefix("echo") }.map(\.trust) == ["trusted", "trusted"])

            let moved = URL(filePath: "/Applications/Other/CuePad.app/Contents/Helpers/cuepad")
            #expect(await integration(cuepad: moved).status(of: .codex).files == .outdated)
            try await integration(cuepad: moved).install(.codex)
            #expect(await integration(cuepad: moved).status(of: .codex).files == .current)
            hooks = try await codex.hookTrust()
            #expect(hooks.filter { $0.command == "\(moved.path) hook codex" }.allSatisfy { $0.trust == "trusted" })
            #expect(!hooks.contains { $0.command == command })

            try await integration(cuepad: moved).uninstall(.codex, executable: codex.locator.candidates("codex").first)

            #expect(try Data(contentsOf: hooksFile) == before.0)
            #expect(try Data(contentsOf: configFile) == before.1)
            #expect(await integration().status(of: .codex).files == .missing)
        }
    }
}
#endif
