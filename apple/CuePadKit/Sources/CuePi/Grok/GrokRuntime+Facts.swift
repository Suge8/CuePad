#if os(macOS)
import CueStore
import Foundation

extension GrokRuntime {
    /// 官方脚本装进 `~/.grok/bin`，自带 `grok update` 升级。要的版本是验过 ACP 用法（`_meta.agentProfile`、`_x.ai/interject`）的最旧一版。
    /// 会话记录是每个会话目录里的 `updates.jsonl`（`GrokHistory`）；不装上报通道（终端会话只读跟读它，见 `GrokRuntime`）。
    /// 技能：除了自己的 `skills`，也递归读几家共读的 `~/.agents/skills`（`SharedSkills.recursive`）与 Claude Code 的 `~/.claude/skills`（按名字去重，见它的文档 08-skills）；
    /// 全局规则是自己目录下的 `AGENTS.md`（文档 12-project-rules），链到共读的那份。
    nonisolated public static let facts = AgentFacts(
        command: "grok", homeVariable: "GROK_HOME", home: home, minimumVersion: AgentVersion(1, 0, 52),
        installScript: "curl -fsSL https://x.ai/cli/install.sh | bash", upgradeCommand: "grok update", loginArguments: ["login"],
        sessionFiles: SessionFileFormat(ingest: GrokHistory.ingest, depth: 3, naming: .inDirectory(file: "updates.jsonl", cwdInPath: true)) {
            home($0).appending(path: "sessions", directoryHint: .isDirectory)
        },
        releasesIdleHosted: true, probe: ask, brain: { ACPSession(dialect: GrokDialect()) }, projectFolder: ".grok")

    nonisolated private static func home(_ paths: AgentPaths) -> URL { paths.directory(facts.homeVariable) ?? paths.user(".grok") }

    /// 起 ACP 服务、只握手（不开会话、不落记录）：握手的 `_meta` 里有默认的登录方式（没有就是没登录：没有登录过的凭据、也没有 API 密钥）
    /// 与模型清单（`modelState`：默认模型、每个模型能用的思考强度）。
    private static func ask(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        let environment = probe.locator.environment(
            launching: executable, overrides: probe.paths.environment.merging([facts.homeVariable: home(probe.paths).path]) { $1 })
        let connection = try await ACPConnection.launch(executable, GrokDialect().arguments, environment: environment)
        let meta = connection.agent["_meta"]
        await connection.shutdown()
        guard meta?["defaultAuthMethodId"]?.string != nil, let state = meta?["modelState"] else { return nil }
        let models = (state["availableModels"]?.array ?? []).compactMap { model -> PiModelOption? in
            guard let id = model["modelId"]?.string else { return nil }
            let levels = (model["_meta"]?["reasoningEfforts"]?.array ?? []).compactMap { $0["value"]?.string.flatMap(PiThinkingLevel.init(rawValue:)) }
            return PiModelOption(key: PiModelKey(provider: AgentKind.grok.rawValue, id: id), name: model["name"]?.string ?? id, thinkingLevels: levels)
        }
        let current = state["currentModelId"]?.string.map { PiModelKey(provider: AgentKind.grok.rawValue, id: $0) }
        return MacAgent(kind: .grok, model: current, models: models)
    }
}
#endif
