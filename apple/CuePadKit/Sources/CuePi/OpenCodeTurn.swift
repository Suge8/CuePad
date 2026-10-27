#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 一个 OpenCode 会话的一轮：这个会话的事件（`OpenCodeEvent`）在这里翻成 `TurnEvent`，接入（顶层会话与子代理）与大脑同用这一份，
/// 别处不再解读执行、步骤、工具与正文的事件。
/// - 一轮是一次执行：`session.execution.started` 开始，`succeeded` / `failed` / `interrupted` 结束；失败先报原文（`error.message`，没有就是
///   `error.type`）。被停下（`interrupted`）的照常结束、不报失败；
/// - 工具：`tool.called` 不带名字，名字在它之前的 `tool.input.started` 里；结果是成功时内容块里的文字、失败时的错误原文；
/// - 上下文：每一步结束（`step.ended`）报这一步的输入合计（`OpenCodeTokens.prompt`）与这一步用的模型（`step.started` 带着）的窗口；
/// - 正在说的话：一条回答（`assistantMessageID`）的段号是 `ordinal`（与对话里这条回答的写法一致，见 `OpenCodeHistory`），正文的增量追加，
///   一段说完（`text.ended`）换成这段的全文；换一条回答就重来；转成工具调用、下一轮开始、这一轮停下或失败时清掉，正常说完的留着。
///   `since` 取这一步开始（`step.started` 的 `started`）的时刻，不取第一个增量到的时刻：对话里这条回答的时刻是这条消息建立的时刻
///   （`OpenCodeMessage.at`，同一个毫秒数、同一种换算），早于第一个字；取后者，界面认不出它已落库（`PiDraft.landed`），说完后草稿与
///   对话里的回答会叠成两份。没看到这一步开始（中途连上）的回答不给草稿。服务不续传：断线重连后从头再来（换一个新的）。
struct OpenCodeTurn {
    private var draft: DraftParts?
    /// 最近开始的一步：哪条回答、它的时刻、用的模型
    private var step: (message: String?, at: Date?, model: OpenCodeModelRef?)?
    /// 在跑的工具调用 → 名字
    private var toolNames: [String: String] = [:]

    /// 还有工具在跑（并行调用时一个做完了别的还在）
    var runningTools: Bool { !toolNames.isEmpty }
    var speaking: Bool { draft?.draft != nil }

    /// 这条事件翻成的 `TurnEvent`（按先后）。`models` 是这个会话能用的模型（取上下文窗口）。
    mutating func apply(_ event: OpenCodeEvent, models: [OpenCodeModel]) -> [TurnEvent] {
        let data = event.data
        switch event.type {
        case "session.execution.started":
            toolNames = [:]
            return clearDraft() + [.turnStarted]
        case "session.step.started":
            step = (data.assistantMessageID, data.started.map { Date(timeIntervalSince1970: $0 / 1000) }, data.model)
            return []
        case "session.text.delta":
            guard let message = data.assistantMessageID, let delta = data.delta else { return [] }
            if draft?.message != message {
                guard let step, step.message == message, let at = step.at else { return [] }
                draft = DraftParts(message: message, since: at)
            }
            draft?.append(delta, to: data.ordinal ?? 0)
            return [.speaking(draft?.draft)]
        case "session.text.ended":
            guard draft?.message == data.assistantMessageID, let text = data.text else { return [] }
            draft?.finish(data.ordinal ?? 0, with: text)
            return [.speaking(draft?.draft)]
        case "session.step.ended":
            guard let tokens = data.tokens else { return [] }
            return [.context(used: tokens.prompt, window: Self.window(of: step?.model, in: models))]
        case "session.tool.input.started":
            if let id = data.id, let name = data.name { toolNames[id] = name }
            return clearDraft()
        case "session.tool.called":
            guard let id = data.id else { return [] }
            let name = toolNames[id] ?? "tool"
            let bare = name.hasPrefix(Self.cuePadPrefix) ? String(name.dropFirst(Self.cuePadPrefix.count)) : name
            return [.tool(id: id, name: bare.lowercased(), arguments: String(decoding: (data.input?.json ?? [:]).data, as: UTF8.self))]
        case "session.tool.success", "session.tool.failed":
            guard let id = data.id else { return [] }
            toolNames[id] = nil
            let failed = event.type == "session.tool.failed"
            return [.toolDone(id: id, result: failed ? data.error?.message ?? "" : brainText(data.content), failed: failed)]
        case "session.execution.succeeded":
            toolNames = [:]
            return [.turnFinished]
        case "session.execution.failed", "session.execution.interrupted":
            toolNames = [:]
            let failure = event.type == "session.execution.failed" ? [TurnEvent.failed(data.error?.message ?? data.error?.type ?? Self.unknownFailure)] : []
            return clearDraft() + failure + [.turnFinished]
        default:
            return []
        }
    }

    private mutating func clearDraft() -> [TurnEvent] {
        guard draft != nil else { return [] }
        draft = nil
        return [.speaking(nil)]
    }

    /// 模型的上下文窗口：`models` 里没有这个模型时为 nil。
    static func window(of model: OpenCodeModelRef?, in models: [OpenCodeModel]) -> Int? {
        guard let model else { return nil }
        return models.first { $0.id == model.id && $0.providerID == model.providerID }?.limit?.context
    }

    /// CuePad 的 MCP 工具在 OpenCode 里的前缀（`<服务>_<工具>`）
    static let cuePadPrefix = "\(CueMCPServer.name)_"
    static let unknownFailure = String(localized: "出错了，原因不明")
}
extension TurnEvent {
    /// 改的不只是正在说的话（正在说的话直接交给桥，不用重新发布整个会话）
    var changesFacts: Bool { if case .speaking = self { false } else { true } }
}
#endif
