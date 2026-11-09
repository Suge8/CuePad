#if os(macOS)
import CueStore
import Foundation

extension ClaudeCodeRuntime {
    /// 最低 2.1.169：从这版起 stream-json 报带标识的话被哪一轮收下（`command_lifecycle` 的 `command_uuid`），大脑据此报 `received`（2.1.168 没有）；
    /// 钩子环境里的 `CLAUDE_CODE_SESSION_ID`（2.1.145 起）也就有了，钩子入口靠它认出是 Claude Code 发的（`ClaudeCodeRuntime.received`）。
    nonisolated public static let facts = AgentFacts(
        command: "claude", homeVariable: "CLAUDE_CONFIG_DIR", minimumVersion: AgentVersion(2, 1, 169),
        installScript: "curl -fsSL https://claude.ai/install.sh | bash",
        loginArguments: ["auth", "login"],
        sessionFiles: SessionFileFormat(ingest: ClaudeHistory.ingest, depth: 2, naming: .id) {
            $0.home(of: .claudeCode).appending(path: "projects", directoryHint: .isDirectory)
        },
        channel: { integration, _ in HookFile.claudeCode(home: integration.home(of: .claudeCode), skillDirectory: integration.skillDirectory) },
        releasesIdleHosted: true, probe: askClaude, brain: { ClaudeHostedSession() }, sharedSkills: .none, projectFolder: ".claude", selfManagedSkills: "synced",
        instructionsFile: "CLAUDE.md")

    /// stream-json 不存会话、关掉钩子（否则 CuePad 自己的钩子把它报成一个会话）、不起 MCP 服务，控制请求 `initialize` 给模型清单，
    /// 其中的 `account` 没有令牌也没有 API 密钥是没登录；`get_settings` 的 `applied.model` 是按用户配置解析出的实际模型。默认落到清单
    /// （`ClaudeCode.models`）里解析出同一个模型的第一项（`opus` 这样的别名排在完整 id 前面），对不上时只有 id。
    private static func askClaude(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        let arguments = [
            "-p", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--disable-slash-commands",
        ]
        let stream = try await ClaudeStream(
            executable: executable, arguments: arguments, directory: FileManager.default.temporaryDirectory,
            environment: probe.locator.environment(launching: executable, overrides: probe.paths.environment))
        return try await withStopped(stream, stop: { await $0.process.stop() }, models)
    }

    private static func models(_ stream: ClaudeStream) async throws -> MacAgent? {
        let info = try await stream.request(["subtype": "initialize"])
        let account = info["account"]
        let signedIn = account?["tokenSource"]?.string != "none" || account?["apiKeySource"]?.string != nil
            || account?["apiProvider"]?.string != "firstParty"
        guard signedIn else { return nil }
        let applied = try await stream.request(["subtype": "get_settings"])["applied"]?["model"]?.string
        let offered = ClaudeCode.models(in: info)
        let model = offered.first { $0.resolved == applied }?.option.key ?? applied.map { ClaudeCode.model($0).key }
        return MacAgent(kind: .claudeCode, model: model, models: offered.map(\.option))
    }
}
#endif
