#if os(macOS)
import CueStore
import Foundation

extension ClaudeCodeRuntime {
    /// 最低 2.1.169：从这版起 stream-json 报带标识的话被哪一轮收下（`command_lifecycle` 的 `command_uuid`），大脑据此报 `received`（2.1.168 没有）；
    /// 全局规则读配置目录里的 `CLAUDE.md` 与 `rules/` 下每一份（2.1.318 实测，配置目录换了位置、链接都照读），共享的那份链成 `rules/AGENTS.md`。
    /// 不链成 `CLAUDE.md`：它往上找项目规则时把 `~/.claude/CLAUDE.md` 当成 ~ 这一层的 CLAUDE.md，有它在 ~ 下各项目的 AGENTS.md 就都不读了（实测）。
    /// 配置目录里的 `AGENTS.md` 它按目录层级读：在 ~ 下干活、一路没有 CLAUDE.md 时当 ~ 这一层的项目规则读到。项目都在 ~ 下，
    /// 所以这份对所有项目生效，页面当全局规则列、整理时并进共享那份（`AgentLibraryPlaces.globalFiles`）。
    nonisolated public static let facts = AgentFacts(
        command: "claude", homeVariable: "CLAUDE_CONFIG_DIR", minimumVersion: AgentVersion(2, 1, 169),
        installScript: "curl -fsSL https://claude.ai/install.sh | bash", installDirectory: ".local/bin",
        loginArguments: ["auth", "login"],
        sessionFiles: SessionFileFormat(ingest: ClaudeHistory.ingest, depth: 2, naming: .id) {
            $0.home(of: .claudeCode).appending(path: "projects", directoryHint: .isDirectory)
        },
        releasesIdleHosted: true, probe: askClaude, brain: { ClaudeHostedSession(timing: .system) }, sharedSkills: .none, projectFolder: ".claude", selfManagedSkills: "synced",
        instructionsFile: "rules/AGENTS.md", globalReads: ["CLAUDE.md", "rules/AGENTS.md"], readsFirstOnly: false, compactsAt: compactsAt)

    /// 官方文档 model-config 与 settings-reference 的 auto-compact：关了（`autoCompactEnabled`、`DISABLE_AUTO_COMPACT`）不压缩；设了窗口就到它压缩——
    /// 环境变量（不到 100K 当 100K、超过 1M 当 1M、读不懂的不算）先于 `/autocompact` 按模型存的（`modelSettings`，`"auto"` 是不设），
    /// 再是 `autoCompactWindow`；没设时到窗口的边，原生 1M 窗口的约在 967K；百分比的覆盖只往低里调。环境变量也认设置里 `env` 写的。
    nonisolated private static func compactsAt(_ window: Int, _ model: ModelKey?, _ paths: AgentPaths) -> Int? {
        let settings = paths.home(of: .claudeCode).appending(path: "settings.json")
        func env(_ name: String) -> String? { paths.environment[name] ?? AgentSettings.json(settings, "env", name) as? String }
        let disabled = env("DISABLE_AUTO_COMPACT").map { !["", "0", "false"].contains($0.lowercased()) } ?? false
        guard !disabled, AgentSettings.json(settings, "autoCompactEnabled") as? Bool != false else { return nil }
        let tuned = window >= 1_000_000 ? window - 33_000 : window
        let forced = env("CLAUDE_CODE_AUTO_COMPACT_WINDOW").flatMap(tokens).map { min(max($0, 100_000), 1_000_000) }
        let saved = model.flatMap { saved(for: $0.id, in: AgentSettings.json(settings, "modelSettings") as? [String: Any] ?? [:]) }
        let set = forced ?? (saved is String ? nil : saved as? Int ?? AgentSettings.json(settings, "autoCompactWindow") as? Int)
        let at = min(set ?? tuned, window)
        guard let percent = env("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE").flatMap({ Int($0) }), (1...100).contains(percent) else { return at }
        return min(at, window * percent / 100)
    }

    /// `200000`、`200k`、`1M`；别的写法读不懂。
    nonisolated private static func tokens(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        let scale = text.hasSuffix("k") ? 1_000.0 : text.hasSuffix("m") ? 1_000_000.0 : 1
        return Double(scale == 1 ? text : String(text.dropLast())).flatMap { $0 > 0 ? Int($0 * scale) : nil }
    }

    /// 按模型存的窗口记在模型的正式名下（`claude-opus-5-5`），会话里的 id 可能带日期、带 `[1m]`，也可能是别名（`opus`）：
    /// 先找同名的，再找是这个 id 开头一段的，别名只在恰好一条的名字里有它时才认（两代 Opus 都存过就分不出是哪条，照没存算）。
    nonisolated private static func saved(for id: String, in models: [String: Any]) -> Any? {
        let id = id.split(separator: "[")[0].lowercased()
        let named = models.keys.filter { id == $0.lowercased() || id.hasPrefix($0.lowercased()) }.max { $0.count < $1.count }
        let aliased = models.keys.filter { $0.lowercased().split(separator: "-").contains(Substring(id)) }
        return (named ?? (aliased.count == 1 ? aliased[0] : nil)).flatMap { (models[$0] as? [String: Any])?["autoCompactWindow"] }
    }

    /// stream-json 不存会话、关掉钩子、不起 MCP 服务，控制请求 `initialize` 给模型清单，
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
