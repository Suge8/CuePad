#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 起一个大脑要的本机信息：只找可执行文件，不问登录（登录不了大脑会起不来或一轮出错，由管理器报出）。
nonisolated struct CueLaunch: Equatable, Sendable {
    var executable: URL
    /// 给大脑与 MCP 服务的 PATH（`ExecutableLocator.resolved`）：App 自己的 PATH 很短，运行时起的 node 等靠它找到。
    var path: String
    /// 开会话可选的 Agent 与模型，一项一行、能照抄进 start（`CuePrompt.system` 的 `agents`）
    var agents: [String]
}

/// 查本机的 Pi、Codex、Claude Code 能不能当大脑：按 `ExecutableLocator.resolved` 找可执行文件，`scan()` 再用各家自己的命令问登录了没有
/// （Pi 是 `--list-models` 有没有可用模型，Codex 是 `login status` 的退出码，Claude Code 是 `auth status` 的 `loggedIn`）。
/// 状态命令慢（每条最多等 `timeout`），只在启用、换运行时与大脑起不来时跑；每个班次开始只用 `launch(_:store:)`。只读，不改任何一家的配置。
nonisolated struct CueRuntimes: Sendable {
    private static let timeout: Duration = .seconds(15)

    var integration: AgentIntegration
    /// Pi 的配置目录（`PiPaths.agentDirectory`）：登录状态与默认模型从这里读。
    var piAgentDirectory: URL
    /// 这台 Mac（会话记录的 `hostID`）：各家最近用的模型从这台的会话记录里取
    var hostID: String
    var locator: @Sendable () async -> ExecutableLocator = { await .resolved() }

    /// 装了且登录了的，按 `CueProfile.runtimes` 的顺序。
    @concurrent func scan() async -> [AgentKind] {
        let locator = await locator()
        let path = locator.path
        func found(_ kind: AgentKind) -> URL? { locator.candidates(kind.command).first }
        async let pi = loggedIn(found(.pi), ["--list-models"], path: path) { _, output in
            let rows = output.split(separator: "\n")
            return rows.first?.hasPrefix("provider") == true && rows.count > 1  // 没登录时只有一句"No models available…"
        }
        async let codex = loggedIn(found(.codex), ["login", "status"], path: path) { status, _ in status == 0 }
        async let claude = loggedIn(found(.claudeCode), ["auth", "status"], path: path) { _, output in
            (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["loggedIn"] as? Bool == true
        }
        let ready: [AgentKind: Bool] = await [.pi: pi, .codex: codex, .claudeCode: claude]
        return CueProfile.runtimes.filter { ready[$0] == true }
    }

    /// 起 `runtime` 的大脑要的可执行文件、PATH 与可选的 Agent 和模型；没装为 nil。
    @concurrent func launch(_ runtime: AgentKind, store: CueStore) async -> CueLaunch? {
        let locator = await locator()
        guard let executable = locator.candidates(runtime.command).first else { return nil }
        return CueLaunch(executable: executable, path: locator.path, agents: await agents(store: store))
    }

    /// 能开新会话的 Agent（与开新会话同一个条件 `AgentStatus.canLaunch`），按 `AgentKind` 的顺序，一家一行 `agent=…, model=…`：
    /// Pi 是设置里的默认模型（标"默认"）与 `enabledModels`，其余是这台 Mac 上它最近一个会话记录里的模型；没有模型的只写 agent（用它自己的默认）。
    /// 模型按这家的写法（`AgentKind.modelRef`）。
    private func agents(store: CueStore) async -> [String] {
        let statuses = await withTaskGroup(of: (AgentKind, Bool).self) { group in
            for kind in AgentKind.allCases { group.addTask { (kind, await integration.status(of: kind).canLaunch) } }
            return await group.reduce(into: [AgentKind: Bool]()) { $0[$1.0] = $1.1 }
        }
        let recent = (try? await store.latestModels(on: hostID)) ?? [:]
        return AgentKind.allCases.filter { statuses[$0] == true }.flatMap { kind -> [String] in
            let line = "agent=\(kind.rawValue)"
            guard kind == .pi else {
                return [recent[kind].map { "\(line), model=" + kind.modelRef($0) } ?? line]
            }
            let (preferred, enabled) = piModels()
            let models = (preferred.map { [$0] } ?? []) + enabled.filter { $0 != preferred }
            guard !models.isEmpty else { return [line] }
            return models.map { "\(line), model=\($0)" + ($0 == preferred ? "（默认）" : "") }
        }
    }

    /// Pi 设置（`settings.json`）里的默认模型与 `enabledModels`；读不到设置就都没有。
    private func piModels() -> (preferred: String?, enabled: [String]) {
        let file = piAgentDirectory.appending(path: "settings.json")
        guard let settings = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return (nil, []) }
        let preferred = (settings["defaultProvider"] as? String).flatMap { provider in (settings["defaultModel"] as? String).map { "\(provider)/\($0)" } }
        return (preferred, settings["enabledModels"] as? [String] ?? [])
    }

    private func loggedIn(
        _ executable: URL?, _ arguments: [String], path: String, _ check: @Sendable (Int32, String) -> Bool
    ) async -> Bool {
        guard let executable else { return false }
        let environment = ProcessInfo.processInfo.environment
            .merging(["PATH": path, "PI_OFFLINE": "1", "PI_CODING_AGENT_DIR": piAgentDirectory.path]) { $1 }
        guard let result = await runCapturing(executable, arguments, environment: environment, timeout: Self.timeout) else { return false }
        return check(result.status, result.output)
    }
}
#endif
