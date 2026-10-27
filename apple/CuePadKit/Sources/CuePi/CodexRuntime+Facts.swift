#if os(macOS)
import CueStore
import Foundation

extension CodexRuntime {
    /// 会话文件是 `sessions/YYYY/MM/DD/rollout-*.jsonl`。上报通道是钩子与信任（`CodexHooks`，写、删信任要起检测时挑中的那个 codex）；
    /// 托管的进程是 CuePad 起的。自己管 `skills/.system` 里的技能。
    nonisolated public static let facts = AgentFacts(
        command: "codex", homeVariable: "CODEX_HOME", installScript: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        loginArguments: ["login"],
        sessionFiles: SessionFileFormat(ingest: CodexHistory.ingest, depth: 4, naming: .idSuffix) {
            $0.home(of: .codex).appending(path: "sessions", directoryHint: .isDirectory)
        },
        channel: { integration, codex in
            CodexHooks(
                home: integration.home(of: .codex), skillDirectory: integration.skillDirectory, codex: codex, locate: integration.locate,
                environment: integration.paths.environment)
        },
        releasesIdleHosted: true, probe: askCodex, brain: { CodexBrain() }, projectFolder: ".codex", selfManagedSkills: ".system")

    /// `codex app-server` 不开线程（不落会话、不跑钩子）：`getAuthStatus` 没有登录方式且要 OpenAI 登录是没登录（只读本机的登录；
    /// 否决 `account/read`：它要联网查工作区，断网或刚醒时超时就成了没登录）；默认是用户配置的模型（`config/read` 的 `model`），
    /// 没配是 `model/list` 里标了 `isDefault` 的那个。
    private static func askCodex(_ executable: URL, _ probe: AgentProbe) async throws -> MacAgent? {
        let environment = probe.paths.environment.merging([facts.homeVariable: probe.paths.home(of: .codex).path]) { $1 }
        let rpc = try await CodexRPC.launch(executable, environment: probe.locator.environment(launching: executable, overrides: environment))
        do {
            let agent = try await models(rpc)
            await rpc.shutdown()
            return agent
        } catch {
            await rpc.shutdown()
            throw error
        }
    }

    private static func models(_ rpc: CodexRPC) async throws -> MacAgent? {
        let auth = try await rpc.call("getAuthStatus", ["includeToken": false, "refreshToken": false])
        guard auth["authMethod"]?.string != nil || auth["requiresOpenaiAuth"]?.bool == false else { return nil }
        let configured = try await rpc.call("config/read", [:])["config"]?["model"]?.string
        let models = try await CodexModel.list(rpc)
        let model = (configured ?? models.first(where: \.isDefault)?.id).map { PiModelKey(provider: CodexModel.provider, id: $0) }
        return MacAgent(kind: .codex, model: model, models: models.map(\.option))
    }
}
#endif
