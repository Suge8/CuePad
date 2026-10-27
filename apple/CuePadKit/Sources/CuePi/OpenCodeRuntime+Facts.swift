#if os(macOS)
import CueStore
import Foundation

extension OpenCodeRuntime {
    /// 只认 v2（v1 的服务接口不同，不做兼容；Homebrew 与官方脚本装的是 v2，npm 上 v2 是 `@opencode/cli`，旧包 `opencode-ai` 仍是 1.x），
    /// 太旧也是重跑 v2 的安装命令替换它。会话在它的数据库里，由接入直连它的后台服务，不用装上报通道。
    /// 旧技能目录还认单数的 `skill`；全局规则不链：没有自己那份时它读 Claude Code 的。
    nonisolated public static let facts = AgentFacts(
        command: "opencode", homeVariable: "OPENCODE_CONFIG_DIR",
        home: home, minimumVersion: AgentVersion(2, 0, 0), installScript: "curl -fsSL https://opencode.ai/v2/install | bash", probe: ask,
        brain: { OpenCodeBrain() },
        skillFolders: ["skills", "skill"], projectFolder: ".opencode", linksGlobalInstructions: false)

    nonisolated private static func home(_ paths: AgentPaths) -> URL {
        paths.directory(facts.homeVariable) ?? paths.xdg("XDG_CONFIG_HOME", ".config").appending(path: "opencode", directoryHint: .isDirectory)
    }

    /// 能选哪些模型、不指定时用哪个：起一台不开 MCP、不读工作目录配置的服务（`OpenCodeClient.serve`，在临时目录里），
    /// 问 `/api/model`（已连上的提供方的模型，与会话的模型菜单同一份）与 `/api/model/default`（按用户配置解析出的默认），问完关掉。
    /// 免费模型不用登录，所以总有模型；一个都没有（用户关掉了免费模型、又没连提供方）是没登录，返回 nil。
    nonisolated private static func ask(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        let config = jsonString(["policies": [["action": "integration.use", "resource": "mcp:*", "effect": "deny"]]])
        let overrides = probe.paths.environment.merging(["OPENCODE_CONFIG_CONTENT": config, "OPENCODE_DISABLE_PROJECT_CONFIG": "1"]) { $1 }
        let (process, client) = try await OpenCodeClient.serve(
            executable, environment: probe.locator.environment(launching: executable, overrides: overrides),
            directory: FileManager.default.temporaryDirectory)
        do {
            let models = try await client.get(OpenCodeData<[OpenCodeModel]>.self, "/api/model").data
            let model = try await client.get(OpenCodeData<OpenCodeModel?>.self, "/api/model/default").data
            await process.stop()
            return models.isEmpty ? nil : MacAgent(kind: .opencode, model: model?.key, models: models.map(\.option))
        } catch {
            await process.stop()
            throw error
        }
    }

    /// 关掉开关：CuePad 拉起的服务一并停掉（本来就在跑的不动）。
    public func integrationRemoved() async { await stopStartedService()() }
}
#endif
