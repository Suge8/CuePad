#if DEBUG
import CueStore
import CueText
import Foundation

extension DebugScene {
    static func model(_ provider: String, _ id: String, _ name: String, _ levels: [PiThinkingLevel]) -> PiModelOption {
        PiModelOption(key: PiModelKey(provider: provider, id: id), name: name, thinkingLevels: levels)
    }

    /// 演示会话的模型配置，按哪家 Agent：Pi 的模型带提供方（几家各一两个，最后一个是用户自定义的提供方，菜单里不带标志）；
    /// OpenCode 的经 OpenRouter 转发（id 形如 `anthropic/claude-…`，标志按模型家族认）；
    /// Codex 与 Claude Code 是它们自己报的清单，照录像带里 Codex 的 `model/list`（GPT 系，`ultra` 不是 CuePad 认识的档，不列）
    /// 与 Claude Code 的 `initialize`（Claude 系），提供方是这一家（`AgentKind.modelProvider`），与真会话上报的一样。
    static func demoModels(for agent: AgentKind?) -> PiModelState {
        func listed(_ models: [PiModelOption], current: Int, thinking: PiThinkingLevel) -> PiModelState {
            PiModelState(model: models[current], thinking: .known(thinking), models: models)
        }
        let levels: [PiThinkingLevel] = [.low, .medium, .high, .xhigh, .max]
        switch agent {
        case .opencode:
            return listed([
                model("openrouter", "anthropic/claude-sonnet-5", "Claude Sonnet 5", [.low, .medium, .high]),
                model("openrouter", "google/gemini-3-pro", "Gemini 3 Pro", [.low, .high]),
                model("openrouter", "qwen/qwen3-coder", "Qwen3 Coder", [.off]),
            ], current: 0, thinking: .medium)
        case .codex:
            let provider = AgentKind.codex.modelProvider ?? ""
            return listed([
                model(provider, "gpt-6.1-sol", "GPT-6.1-Sol", levels), model(provider, "gpt-6-astra", "GPT-6-Astra", levels),
                model(provider, "gpt-6-sol", "GPT-6-Sol", levels), model(provider, "gpt-6-luna", "GPT-6-Luna", levels),
                model(provider, "gpt-5.6-terra", "GPT-5.6-Terra", levels),
            ], current: 0, thinking: .medium)
        case .claudeCode:
            let provider = AgentKind.claudeCode.modelProvider ?? ""
            return listed([
                model(provider, "default", "Default (recommended)", levels), model(provider, "opus", "Opus", levels),
                model(provider, "fable", "Fable", levels), model(provider, "sonnet", "Sonnet", levels), model(provider, "haiku", "Haiku", levels),
            ], current: 1, thinking: .high)
        case .pi, nil:
            return demoModels
        }
    }

    static let demoModels: PiModelState = {
        let opus = model("anthropic", "claude-opus-5-5-20260901", "Claude Opus 5.5", [.low, .medium, .high, .max])
        return PiModelState(model: opus, thinking: .known(.medium), models: [
            opus,
            model("anthropic", "claude-sonnet-5-20260801", "Claude Sonnet 5", [.off, .low, .medium, .high]),
            model("openai-codex", "gpt-6-luna", "GPT-6 Luna", [.off, .low, .high]),
            model("xai", "grok-5", "Grok 5", [.low, .high]),
            model("deepseek", "deepseek-v4", "DeepSeek V4", [.off, .high]),
            model("kimi-coding", "kimi-k3", "Kimi K3", [.off]),
            model("xiaomi", "mimo-v3-pro", "MiMo V3 Pro", [.off, .high]),
            model("lab-proxy", "house-1", "", [.off]),
        ])
    }()

    /// 演示会话的斜杠命令清单：内置、扩展、提示词模板、技能各有几条（回复框输入 "/" 弹出的面板）。
    static let demoCommands = [
        PiSlashCommand(name: "compact", summary: String(localized: "压缩当前上下文，可附上说明", table: "Demo"), source: .known(.builtin), hint: String(localized: "[说明]", table: "Demo")),
        PiSlashCommand(name: "name", summary: String(localized: "设置会话名", table: "Demo"), source: .known(.builtin), hint: String(localized: "<名字>", table: "Demo")),
        PiSlashCommand(name: "model", summary: String(localized: "换模型", table: "Demo"), source: .known(.builtin), hint: String(localized: "<提供方/模型>", table: "Demo")),
        PiSlashCommand(name: "thinking", summary: String(localized: "设置思考强度", table: "Demo"), source: .known(.builtin), hint: String(localized: "<强度>", table: "Demo")),
        PiSlashCommand(name: "new", summary: String(localized: "开一个新会话", table: "Demo"), source: .known(.builtin)),
        PiSlashCommand(name: "clone", summary: String(localized: "在当前位置复制出一个新会话", table: "Demo"), source: .known(.builtin)),
        PiSlashCommand(name: "reload", summary: String(localized: "重新载入扩展、skill、提示词模板与上下文文件", table: "Demo"), source: .known(.builtin)),
        PiSlashCommand(name: "plan", summary: String(localized: "先列计划，确认后再动手", table: "Demo"), source: .known(.extension)),
        PiSlashCommand(name: "review", summary: String(localized: "审查当前分支的改动", table: "Demo"), source: .known(.prompt)),
        PiSlashCommand(name: "changelog", summary: String(localized: "按提交记录写更新说明", table: "Demo"), source: .known(.prompt)),
        PiSlashCommand(name: "skill:deploy", summary: String(localized: "按清单检查并部署到生产", table: "Demo"), source: .known(.skill)),
        PiSlashCommand(name: "skill:frontend-design", summary: String(localized: "做界面时先定视觉方向与密度", table: "Demo"), source: .known(.skill)),
    ]

    /// 演示会话的上下文用量（窗口 20 万 token）：多数宽裕，atlas 用到八成多（百分比加粗转墨色、说明里建议压缩），
    /// rename 用到九成多（胭脂那一档），billing 刚压缩过。
    static let demoContexts: [String: PiContextUsage] = [
        "atlas": PiContextUsage(tokens: 172_000, window: 200_000),
        "homepage": PiContextUsage(tokens: 31_000, window: 200_000),
        "cuepad": PiContextUsage(tokens: 96_000, window: 200_000),
        "rename": PiContextUsage(tokens: 188_000, window: 200_000),
        "billing": PiContextUsage(tokens: nil, window: 200_000),
    ]

    /// 演示的几台 Mac 上的 Agent（`MacAgents`，配 `-CuePadDemo YES`）：工作室的 Mac Studio（demo-mac，Cue 运行在这台）与 Mac 上的这台本机
    /// 有 Pi、Claude Code、Codex（OpenCode 没装：新会话里不列它），demo-mini 有 Claude Code 与 Codex；
    /// MacBook Air（demo-air，只绑了 CuePad）一家都不能用，各有原因（新会话里选"CuePad · MacBook Air"看为什么）。
    /// Mac 上给 `-CuePadHost bare` 时本机是一家都不能用的那台（看 + 的悬停与表单里的原因）；本机的记录会被它自己的探测改写成隔离目录里真实的样子。
    /// 各家的模型与不指定时用的那个照演示会话报的（`demoModels(for:)`）。
    static func seedMacAgents(_ services: AppServices) async {
        func agent(_ kind: AgentKind) -> MacAgent {
            let state = demoModels(for: kind)
            return MacAgent(kind: kind, model: state.model?.key, models: state.models)
        }
        let full = [agent(.pi), agent(.claudeCode), agent(.codex)]
        let bare = [MacAgentProblem(kind: .pi, reason: .notLoggedIn)] + [.claudeCode, .codex].map { MacAgentProblem(kind: $0, reason: .notInstalled) }
        let store = services.store
        _ = try? await store.recordMacAgents(host: "demo-mac", name: "Mac Studio", full)
        _ = try? await store.recordMacAgents(host: "demo-mini", name: "Mac mini", [agent(.claudeCode), agent(.codex)])
        _ = try? await store.recordMacAgents(host: "demo-air", name: "MacBook Air", [], problems: bare)
        #if os(macOS)
        let local = services.hostID
        _ = try? await store.recordMacAgents(
            host: local, name: String(localized: "这台 Mac", table: "Demo"), local == "mac-bare" ? [] : full, problems: local == "mac-bare" ? bare : [])
        #endif
    }

    /// 不是 Pi 的演示会话（其余是 Pi）：都开在终端里，能做的按各家（`AgentCapabilities`）——cuepad 是 Claude Code（回复框只有文字、没有停止与模型），
    /// homepage 是 Codex（能作答、换模型，没有斜杠命令），billing 是 OpenCode，历史里的 weekly 是 Claude Code。
    static let demoAgents: [String: AgentKind] = ["cuepad": .claudeCode, "homepage": .codex, "billing": .opencode, "weekly": .claudeCode]
}
#endif
