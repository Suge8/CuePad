#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 接入（顶层会话与子代理）与大脑同用这一份，别处不再解读执行、步骤、工具与正文的事件。
/// 被停下（`interrupted`）的照常结束、不报失败。`tool.called` 不带名字，名字在它之前的 `tool.input.started` 里。
/// 发送标识是这句的 `metadata.cuepadDelivery`，在它进收件箱（`enqueued`）时记下；收件箱里的一句送进会话（`session.inbox.delivered`，同一事务里成为对话里的消息）的那一刻算收下（`received`）。
/// 正在说的话的 `since` 取这一步开始（`step.started` 的 `started`）的时刻，不取第一个增量到的时刻：对话里这条回答的时刻是这条消息建立的时刻
/// （`OpenCodeMessage.at`，同一个毫秒数、同一种换算），早于第一个字；取后者，界面认不出它已落库（`PiDraft.landed`），说完后草稿与
/// 对话里的回答会叠成两份。没看到这一步开始（中途连上）的回答不给草稿。服务不续传：断线重连后从头再来（换一个新的）。
struct OpenCodeTurn {
    private var draft: DraftParts?
    private var step: (message: String?, at: Date?, model: OpenCodeModelRef?)?
    private var toolNames: [String: String] = [:]
    private var inbox: [String: UUID] = [:]

    /// 还有工具在跑（并行调用时一个做完了别的还在）
    var runningTools: Bool { !toolNames.isEmpty }
    var speaking: Bool { draft?.draft != nil }

    mutating func apply(_ event: OpenCodeEvent, models: [OpenCodeModel]) -> [TurnEvent] {
        let data = event.data
        switch event.type {
        case "session.execution.started":
            toolNames = [:]
            return clearDraft() + [.turnStarted]
        case "session.inbox.enqueued":
            if let key = data.inboxID, let sent = data.item?.payload?.metadata?.cuepadDelivery.flatMap(UUID.init(uuidString:)) { inbox[key] = sent }
            return []
        case "session.inbox.delivered":
            return data.inboxID.flatMap { inbox.removeValue(forKey: $0) }.map { [.received($0)] } ?? []
        case "session.inbox.cancelled":
            if let key = data.inboxID { inbox[key] = nil }
            return []
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
            return [.tool(id: id, name: CueMCPServer.bareName(name, on: .opencode), arguments: String(decoding: (data.input?.json ?? [:]).data, as: UTF8.self))]
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

    static func window(of model: OpenCodeModelRef?, in models: [OpenCodeModel]) -> Int? {
        guard let model else { return nil }
        return models.first { $0.id == model.id && $0.providerID == model.providerID }?.limit?.context
    }

    static let unknownFailure = String(localized: "出错了，原因不明")
}
extension TurnEvent {
    /// 改的不只是正在说的话（正在说的话直接交给桥，不用重新发布整个会话）
    var changesFacts: Bool { if case .speaking = self { false } else { true } }
}
#endif
