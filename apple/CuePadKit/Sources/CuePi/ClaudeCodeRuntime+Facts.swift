#if os(macOS)
import CueStore
import Foundation

extension ClaudeCodeRuntime {
    /// 会话文件是 `projects/<项目目录>/<会话 id>.jsonl`。上报通道是钩子（`HookFile.claudeCode`）；托管的进程是 CuePad 起的。
    /// 不读 `~/.agents/skills`（技能逐个链过去），自己往 `skills/synced` 写 claude.ai 同步的技能；全局说明是 `CLAUDE.md`。
    nonisolated public static let facts = AgentFacts(
        command: "claude", homeVariable: "CLAUDE_CONFIG_DIR", home: home, installScript: "curl -fsSL https://claude.ai/install.sh | bash",
        loginArguments: ["auth", "login"],
        sessionFiles: SessionFileFormat(ingest: ClaudeHistory.ingest, depth: 2, nameIsSessionID: true) {
            home($0).appending(path: "projects", directoryHint: .isDirectory)
        },
        channel: { integration, _ in HookFile.claudeCode(home: integration.home(of: .claudeCode), skillDirectory: integration.skillDirectory) },
        releasesIdleHosted: true, probe: askClaude, brain: { ClaudeHostedSession() }, readsSharedSkills: false, projectFolder: ".claude", selfManagedSkills: "synced",
        instructionsFile: "CLAUDE.md")

    nonisolated private static func home(_ paths: AgentPaths) -> URL { paths.directory(facts.homeVariable) ?? paths.user(".claude") }

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
        do {
            let agent = try await models(stream)
            await stream.process.stop()
            return agent
        } catch {
            await stream.process.stop()
            throw error
        }
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
