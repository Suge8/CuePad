#if os(macOS)
import CueStore
import Foundation
import os

/// 问这台 Mac 上的各家 Agent 能不能用、不指定模型时用哪个、能选哪些：得出的就是同步表 macAgents 里这台 Mac 的那条（`MacAgent`）。
/// 能用 = 能开新会话（`AgentStatus.canLaunch`）并且问得出模型（登录了）。每家起一个不落会话、不跑钩子、不连 CuePad 的进程，问完让它退出，
/// 各家并发、各自至多 `AgentTimeouts.probe`；问不出（没登录、出错、超时）就是不能用。只读，不改任何一家的配置。
/// - Pi：RPC 模式、不存会话，只加载随包的桥扩展（不加载装好的那份与其他扩展，也就不连 CuePad）并开探测模式（扩展的 `CUEPAD_PROBE`）：
///   扩展把会话里上报的同一份模型配置写成一行就收尾。可选的与 Pi 的 /model 同一规则，配了范围（`enabledModels`）就是范围内的。
///   没有可用的模型是没登录。
/// - Codex：`codex app-server` 不开线程（不落会话、不跑钩子）：`getAuthStatus` 没有登录方式且要 OpenAI 登录是没登录（只读本机的登录；
///   否决 `account/read`：它要联网查工作区，断网或刚醒时超时就成了没登录）；默认是用户配置的模型（`config/read` 的 `model`），
///   没配是 `model/list` 里标了 `isDefault` 的那个。
/// - Claude Code：stream-json 不存会话、关掉钩子（否则 CuePad 自己的钩子把它报成一个会话）、不起 MCP 服务，控制请求 `initialize` 给模型清单，
///   其中的 `account` 没有令牌也没有 API 密钥是没登录；`get_settings` 的 `applied.model` 是按用户配置解析出的实际模型。清单去掉 `default` 那项
///   （它解析到的是推荐的模型，不一定是配置的），默认落到解析出同一个模型的第一项（`opus` 这样的别名排在完整 id 前面），对不上时只有 id。
/// - OpenCode：没有模型清单，能开新会话就算能用。
extension AgentIntegration {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "agents")

    /// 这台 Mac 上能用的 Agent，按 `AgentKind` 的顺序。
    @concurrent public func available() async -> [MacAgent] {
        let found = await withTaskGroup(of: MacAgent?.self) { group in
            for kind in AgentKind.allCases { group.addTask { await self.probe(kind) } }
            return await group.reduce(into: [MacAgent]()) { if let agent = $1 { $0.append(agent) } }
        }
        return AgentKind.allCases.compactMap { kind in found.first { $0.kind == kind } }
    }

    private func probe(_ kind: AgentKind) async -> MacAgent? {
        let found = await detect(kind)
        guard AgentStatus(presence: found.presence, files: files(of: kind)).canLaunch else { return nil }
        if kind == .opencode { return MacAgent(kind: kind, model: nil, models: []) }
        guard let executable = found.executable else { return nil }
        do {
            let agent = try await withDeadline(AgentTimeouts.probe, orThrow: ProbeError.timedOut) { [self] in
                let locator = await locate()
                switch kind {
                case .pi: return await probePi(executable, locator: locator)
                case .codex: return try await probeCodex(executable, locator: locator)
                case .claudeCode: return try await probeClaude(executable, locator: locator)
                case .opencode: return nil
                }
            }
            if agent == nil { Self.log.notice("\(kind.name, privacy: .public) 没登录") }
            return agent
        } catch {
            Self.log.error("没问出 \(kind.name, privacy: .public) 的模型：\(error, privacy: .public)")
            return nil
        }
    }

    private func probePi(_ executable: URL, locator: ExecutableLocator) async -> MacAgent? {
        let arguments = [
            "--mode", "rpc", "--no-session", "--offline", "--no-extensions", "--extension", PiExtensionBundle.url.path,
            "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files",
        ]
        let environment = locator.environment(launching: executable, overrides: paths.pi.launchEnvironment.merging(["CUEPAD_PROBE": "1"]) { $1 })
        guard let result = await ChildProcess.run(executable, arguments, environment: environment, timeout: AgentTimeouts.probe) else { return nil }
        struct Line: Decodable {
            let cuepadProbe: Models
            struct Models: Decodable {
                let model: PiModelOption?
                let models: [PiModelOption]
            }
        }
        let decoder = JSONDecoder()
        guard let reply = result.output.split(separator: "\n").lazy.compactMap({ try? decoder.decode(Line.self, from: Data($0.utf8)) }).first?.cuepadProbe,
              !reply.models.isEmpty else { return nil }
        return MacAgent(kind: .pi, model: reply.model?.key, models: reply.models)
    }

    @MainActor private func probeCodex(_ executable: URL, locator: ExecutableLocator) async throws -> MacAgent? {
        let environment = paths.environment.merging(["CODEX_HOME": home(of: .codex).path]) { $1 }
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

    @MainActor private func probeClaude(_ executable: URL, locator: ExecutableLocator) async throws -> MacAgent? {
        let arguments = [
            "-p", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--disable-slash-commands",
        ]
        let stream = try ClaudeStream(
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
        let offered = ClaudeCode.models(in: info).filter { $0.option.key.id != "default" }
        let model = offered.first { $0.resolved == applied }?.option.key ?? applied.map { ClaudeCode.model($0).key }
        return MacAgent(kind: .claudeCode, model: model, models: offered.map(\.option))
    }

    private enum ProbeError: Error, CustomStringConvertible {
        case timedOut
        var description: String { "超过 \(AgentTimeouts.probe) 没有回答" }
    }
}
#endif
