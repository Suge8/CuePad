#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// Grok Build 与 ACP 标准不同的地方（`ACPDialect`）。起的是 `grok agent --no-leader stdio`：不连 leader（Grok 常驻的会话进程；连上了
/// CuePad 起的进程只是它的客户端，会话活在 leader 里、退出也不走）。扩展方法与通知都在 `_x.ai/` 下（源码 xai-grok-shell 的 extensions/）：
/// - 一轮：Agent 自己开的一轮（插话落空时它补开一轮，`interject-fallback-…`）从 `_x.ai/queue/changed` 带上 `runningPromptId` 起，
///   每一轮都以 `_x.ai/session_notification` 的 `turn_completed` 结束（出错的原话在 `agent_result`）；
/// - 上下文：每次请求模型的 `response_completed` 的用量，输入是未缓存、缓存读、缓存写三项之和；窗口是会话的模型清单里这个模型的 `totalContextTokens`；
/// - 正忙时插话：`_x.ai/interject`（只收文字），下一次请求模型时并进这一轮，这一轮已经不再请求模型时它自己补开一轮；
/// - 改名：`_x.ai/session/rename`；工具名在 `_meta["x.ai/tool"].name`（标准的 `title` 随后会换成给人看的说法），MCP 工具的结果在 `rawOutput`；
/// - 图：握手不报能收图，实际收（`image_normalize`，太小的丢掉、太大的压缩）；
/// - MCP 服务在会话开好之后才连，连上报 `_x.ai/mcp/server_status`。
///
/// 当大脑（`brain`）：
/// - 配置目录（`GROK_HOME`）换成本次运行的临时目录：会话不落进用户的历史，用户的配置、钩子、技能、记忆、MCP 服务都不读；
///   登录照用用户的（用户给了 `GROK_AUTH_PATH` 照用，否则指到用户配置目录里的 `auth.json`；有 `XAI_API_KEY` 也认）。Claude Code、Cursor 的钩子、技能、规则、
///   MCP 与组织下发的 MCP 都关掉（`compat` 各项、`GROK_MANAGED_MCPS_ENABLED`），工作流清单、每轮摘要、标题刷新、自动更新也关掉；
/// - 系统提示经会话的智能体定义（`_meta.agentProfile`）整份替换（`promptMode: full`）：换模型时也不丢（`systemPromptOverride` 换模型就被清空，
///   源码 model_switch.rs）。系统提示会被当成 MiniJinja 模板渲染（`${{ }}`、`${% %}`），整份包在 raw 块里原样交；
/// - 工具只有读文件的三样（`read_file`、`grep`、`list_dir`），关掉默认注入与 MCP 的搜索、转调工具（`search_tool`、`use_tool`）：
///   MCP 工具不进模型的工具清单（源码 sampler_turn.rs、tool_list.rs），模型照名字直接调的照常执行，所以 CuePad 的工具说明写进系统提示
///   （`CueMCPServer.promptsTools`）；不读 AGENTS.md、不找技能；
/// - 第一条输入只有工作目录与日期（`userMessageTemplate`），没有 Grok 默认的规则、技能、MCP 清单；
/// - 不问权限（`_meta.yoloMode`）：带着智能体定义的会话默认是自动审查，审查本身要请求一次模型、还会拦下 CuePad 的工具；
///   能用的只有读文件与 CuePad 的工具，用不着审查。万一仍来问，驱动一律允许（`ACPSession`）。
struct GrokDialect: ACPDialect {
    var agent: AgentKind { .grok }
    var arguments: [String] { ["agent", "--no-leader", "stdio"] }
    var connectsMCPLater: Bool { true }

    /// 读文件的三样（Grok 的内置工具名）
    static let readingTools = ["read_file", "grep", "list_dir"]
    /// 关掉的环境开关（值写成 Grok 认的样子）
    static let brainSwitches: [String: String] = Dictionary(uniqueKeysWithValues:
        ["CLAUDE", "CURSOR"].flatMap { vendor in ["HOOKS", "MCPS", "SKILLS", "RULES", "AGENTS"].map { ("GROK_\(vendor)_\($0)_ENABLED", "false") } }
        + [("GROK_MANAGED_MCPS_ENABLED", "false"), ("GROK_WORKFLOWS", "0"), ("GROK_TURN_SUMMARY", "0"), ("GROK_TITLE_REFRESH", "0"),
           ("GROK_DISABLE_AUTOUPDATER", "1")])
    static let firstMessage = """
        <user_info>
        Workspace Path: ${{ workspace_path }}
        ${% if today_local %}Today's date: ${{ today_local }}
        ${% endif %}</user_info>
        """

    func brain(_ config: CueBrainConfig, directory: URL) throws -> ACPBrainSetup {
        let home = directory.appending(path: "grok", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        func variable(_ name: String) -> String? {
            (config.environment[name] ?? ProcessInfo.processInfo.environment[name]).flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
        }
        // 用户自己指定的凭据文件照用；没指定时是用户配置目录里的那份（配置目录换成了临时目录，不指过去就找不到）
        let auth = variable("GROK_AUTH_PATH")
            ?? (variable("GROK_HOME").map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok", directoryHint: .isDirectory)).appending(path: "auth.json").path
        let profile: JSONValue = [
            "name": "cue", "description": "Cue", "promptMode": "full", "promptBody": .string("${% raw %}\(config.systemPrompt)${% endraw %}"),
            "tools": .array(Self.readingTools.map(JSONValue.string)), "disallowedTools": ["search_tool", "use_tool"], "injectDefaultTools": false,
            "agentsMd": false, "discoverSkills": false, "userMessageTemplate": ["custom": .string(Self.firstMessage)],
        ]
        return ACPBrainSetup(
            environment: Self.brainSwitches.merging(["GROK_HOME": home.path, "GROK_AUTH_PATH": auth]) { $1 },
            meta: ["agentProfile": profile, "yoloMode": true])
    }

    @MainActor func steer(_ text: String, images: [PiImage], session: String, on connection: ACPConnection) async throws -> Bool {
        guard images.isEmpty else { return false }
        try await connection.call("_x.ai/interject", ["sessionId": .string(session), "text": .string(text)])
        return true
    }

    @MainActor func rename(_ name: String, session: String, cwd: URL, on connection: ACPConnection) async throws -> Bool {
        try await connection.call("_x.ai/session/rename", ["sessionId": .string(session), "title": .string(name), "cwd": .string(cwd.path)])
        return true
    }

    func promptMeta(deliveryID: String?) -> JSONValue? {
        deliveryID.map { ["promptId": .string(GrokHistory.deliveryPrefix + $0)] }
    }

    func signals(_ method: String, _ params: JSONValue) -> [ACPSignal] {
        switch method {
        case "_x.ai/queue/changed":
            return params["runningPromptId"]?.string == nil ? [] : [.turnStarted]
        case "_x.ai/mcp/server_status" where params["name"]?.string == CueMCPServer.name:
            switch params["status"]?.string {
            case "ready": return [.mcp(failure: nil)]
            case "unavailable", "needsauth": return [.mcp(failure: params["reason"]?.string ?? params["status"]?.string)]
            default: return []
            }
        case "_x.ai/session_notification":
            let update = params["update"]
            switch update?["sessionUpdate"]?.string {
            case "turn_completed":
                let failed = update?["stop_reason"]?.string == "error"
                return [.turnFinished(failure: failed ? update?["agent_result"]?.string ?? String(localized: "出错了") : nil)]
            case "response_completed":
                let usage = update?["usage"]
                let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].compactMap { usage?[$0]?.int }.reduce(0, +)
                return [.context(used: used)]
            default: return []
            }
        default:
            return []
        }
    }

    func toolName(_ call: JSONValue) -> String {
        call["_meta"]?["x.ai/tool"]?["name"]?.string ?? call["title"]?.string ?? "?"
    }

    /// 标准的 `content` 里没有时取 `rawOutput`：MCP 工具的是 `output` 里成败那一项（`OkayOutput`、`ErrorOutput`），命令的是给模型的那段输出。
    func toolResult(_ update: JSONValue) -> String {
        let text = ACPContent.text(update["content"])
        guard text.isEmpty, let raw = update["rawOutput"] else { return text }
        if let output = raw["output_for_prompt"]?.string { return output }
        if let output = raw["output"]?.string { return output }
        return raw["output"]?.object?.values.compactMap(\.string).first ?? ACPContent.text(raw["output"])
    }

    func window(of model: String, in session: JSONValue) -> Int? {
        session["models"]?["availableModels"]?.array?.first { $0["modelId"]?.string == model }?["_meta"]?["totalContextTokens"]?.int
    }

    func acceptsImages(_ agent: JSONValue) -> Bool { true }
}
#endif
