#if os(macOS)
import CueStore
import CueText
import Foundation

/// 由已检测出的接入状态（`AgentIntegration.status(of:)`）得出这台 Mac 上各家能不能用（同步表 macAgents 里这台的那条）：
/// 装着、找得到命令行程序的几家问出不指定模型时用哪个、能选哪些（`MacAgent`），问得出、开得出会话才算能用（Pi 还要接入，见 `unconnected`）；
/// 其余与问不出的给出原因（`MacAgentProblem`，接在 Agent 名后面读，用户能照着办）。没接入的 Pi 也问：先报没登录，登录了才报只差接入，
/// 接入面板一打开就给对那一步。只读，不改任何一家的配置。
/// 每家起一个不落会话、不跑钩子、不连 CuePad 的进程，问完让它退出，各家并发、各自至多 `AgentTimeouts.probe`：
/// - Pi：RPC 模式、不存会话，只加载随包的桥扩展（不加载装好的那份与其他扩展，也就不连 CuePad）并开探测模式（扩展的 `CUEPAD_PROBE`）：
///   扩展把会话里上报的同一份模型配置写成一行就收尾。可选的与 Pi 的 /model 同一规则，配了范围（`enabledModels`）就是范围内的。
///   没有可用的模型是没登录。
/// - Codex：`codex app-server` 不开线程（不落会话、不跑钩子）：`getAuthStatus` 没有登录方式且要 OpenAI 登录是没登录（只读本机的登录；
///   否决 `account/read`：它要联网查工作区，断网或刚醒时超时就成了没登录）；默认是用户配置的模型（`config/read` 的 `model`），
///   没配是 `model/list` 里标了 `isDefault` 的那个。
/// - Claude Code：stream-json 不存会话、关掉钩子（否则 CuePad 自己的钩子把它报成一个会话）、不起 MCP 服务，控制请求 `initialize` 给模型清单，
///   其中的 `account` 没有令牌也没有 API 密钥是没登录；`get_settings` 的 `applied.model` 是按用户配置解析出的实际模型。默认落到清单（`ClaudeCode.models`）里
///   解析出同一个模型的第一项（`opus` 这样的别名排在完整 id 前面），对不上时只有 id。
/// - OpenCode：没有模型清单，找得到命令行程序就算能用。
/// 起的是检测时挑中的那个可执行文件（`AgentStatus.executable`，与开会话、起大脑同一个）。
struct AgentProbe {
    let paths: AgentPaths
    let locator: ExecutableLocator
    let timing: Timing

    private enum Outcome: Sendable {
        case usable(MacAgent)
        case unusable(MacAgentProblem.Reason)
    }

    func run(_ statuses: [AgentKind: AgentStatus]) async -> (agents: [MacAgent], problems: [MacAgentProblem]) {
        let outcomes = await withTaskGroup(of: (AgentKind, Outcome).self) { group in
            for (kind, status) in statuses { group.addTask { (kind, await outcome(kind, status)) } }
            return await group.reduce(into: [AgentKind: Outcome]()) { $0[$1.0] = $1.1 }
        }
        var agents: [MacAgent] = [], problems: [MacAgentProblem] = []
        for kind in AgentKind.allCases {
            switch outcomes[kind] {
            case .usable(let agent)?: agents.append(agent)
            case .unusable(let reason)?: problems.append(MacAgentProblem(kind: kind, reason: reason))
            case nil: break
            }
        }
        return (agents, problems)
    }

    private func outcome(_ kind: AgentKind, _ status: AgentStatus) async -> Outcome {
        if let reason = Self.absent(kind, status) { return .unusable(reason) }
        guard let executable = status.executable else { return .unusable(.other(String(localized: "没找到它的命令行程序"))) }
        if kind == .opencode { return .usable(MacAgent(kind: kind, model: nil, models: [])) }
        do {
            let agent: MacAgent? = try await withDeadline(AgentTimeouts.probe, timing: timing, orThrow: ProbeError.timedOut) { [self] in
                switch kind {
                case .pi: return try await askPi(executable)
                case .codex: return try await askCodex(executable)
                case .claudeCode: return try await askClaude(executable)
                case .opencode: return nil
                }
            }
            guard let agent else { return .unusable(.notLoggedIn) }
            return Self.unconnected(kind, status).map(Outcome.unusable) ?? .usable(agent)
        } catch {
            let message = error.localizedDescription
            return .unusable(.other(String(localized: "问不出模型（\(message.clipped(Self.messageLimit))）")))
        }
    }

    /// 原因里错误原话的字符数上限（含省略号）：原因跟着同步记录走，界面只显示一行。
    private static let messageLimit = 60

    /// 没装或太旧的原因（不用问）；装着为 nil。
    private static func absent(_ kind: AgentKind, _ status: AgentStatus) -> MacAgentProblem.Reason? {
        switch status.presence {
        case .notFound: .notInstalled
        case .unresponsive: .other(String(localized: "问版本没有回应，稍后再试"))
        case .tooOld(let version): .other(String(localized: "版本太旧（\(version.description)，要 \(kind.minimumVersion?.description ?? "") 或更新）"))
        case .found: nil
        }
    }

    /// 问得出、却因为没接入开不出会话的原因；开得出为 nil。CuePad 写给 Claude Code、Codex、OpenCode 的文件（技能、钩子）只管终端里开的会话与历史，
    /// 后台开的会话由 CuePad 直接托管（OpenCode 连它的服务），没接入照样开得出；托管的 Pi 经桥扩展上报，没接入就开不出来。
    private static func unconnected(_ kind: AgentKind, _ status: AgentStatus) -> MacAgentProblem.Reason? {
        guard kind == .pi else { return nil }
        switch status.files {
        case .missing: return .notConnected
        case .foreign(let path): return .other(String(localized: "接不上：\(path) 是别人的同名文件"))
        case .current, .outdated: return nil
        }
    }

    /// 返回 nil 是没登录；没回答抛错。
    private func askPi(_ executable: URL) async throws -> MacAgent? {
        let arguments = [
            "--mode", "rpc", "--no-session", "--offline", "--no-extensions", "--extension", PiExtensionBundle.url.path,
            "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files",
        ]
        let environment = locator.environment(launching: executable, overrides: paths.pi.launchEnvironment.merging(["CUEPAD_PROBE": "1"]) { $1 })
        guard let result = await ChildProcess.run(executable, arguments, environment: environment, timeout: AgentTimeouts.probe, timing: timing) else {
            throw ProbeError.timedOut
        }
        struct Line: Decodable {
            let cuepadProbe: Models
            struct Models: Decodable {
                let model: PiModelOption?
                let models: [PiModelOption]
            }
        }
        let decoder = JSONDecoder()
        guard let reply = result.output.split(separator: "\n").lazy.compactMap({ try? decoder.decode(Line.self, from: Data($0.utf8)) }).first?.cuepadProbe
        else { throw ProbeError.noAnswer(status: result.status) }
        return reply.models.isEmpty ? nil : MacAgent(kind: .pi, model: reply.model?.key, models: reply.models)
    }

    @MainActor private func askCodex(_ executable: URL) async throws -> MacAgent? {
        let environment = paths.environment.merging(["CODEX_HOME": paths.home(of: .codex).path]) { $1 }
        let rpc = try await CodexRPC.launch(executable, environment: locator.environment(launching: executable, overrides: environment))
        do {
            let agent = try await Self.codexModels(rpc)
            await rpc.shutdown()
            return agent
        } catch {
            await rpc.shutdown()
            throw error
        }
    }

    @MainActor private static func codexModels(_ rpc: CodexRPC) async throws -> MacAgent? {
        let auth = try await rpc.call("getAuthStatus", ["includeToken": false, "refreshToken": false])
        guard auth["authMethod"]?.string != nil || auth["requiresOpenaiAuth"]?.bool == false else { return nil }
        let configured = try await rpc.call("config/read", [:])["config"]?["model"]?.string
        let models = try await CodexModel.list(rpc)
        let model = (configured ?? models.first(where: \.isDefault)?.id).map { PiModelKey(provider: CodexModel.provider, id: $0) }
        return MacAgent(kind: .codex, model: model, models: models.map(\.option))
    }

    @MainActor private func askClaude(_ executable: URL) async throws -> MacAgent? {
        let arguments = [
            "-p", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--disable-slash-commands",
        ]
        let stream = try await ClaudeStream(
            executable: executable, arguments: arguments, directory: FileManager.default.temporaryDirectory,
            environment: locator.environment(launching: executable, overrides: paths.environment))
        do {
            let agent = try await Self.claudeModels(stream)
            await stream.process.stop()
            return agent
        } catch {
            await stream.process.stop()
            throw error
        }
    }

    @MainActor private static func claudeModels(_ stream: ClaudeStream) async throws -> MacAgent? {
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

    private enum ProbeError: LocalizedError {
        case timedOut
        case noAnswer(status: Int32)
        var errorDescription: String? {
            switch self {
            case .timedOut: String(localized: "\(AgentTimeouts.probe.components.seconds) 秒没回答")
            case .noAnswer(let status): String(localized: "没报模型就退出了，退出码 \(status)")
            }
        }
    }
}
#endif
