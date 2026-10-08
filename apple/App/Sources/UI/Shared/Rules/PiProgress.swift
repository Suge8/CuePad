import CueStore
import Foundation

/// 会话行的第三行（全 App 的会话行同一条，`PiSessionRow`）：结束请求的进度 → 回复框里没发的草稿 → 到哪了（`PiProgress`）→ 新会话的提示。
/// 什么都没有时是 nil，行照样留着这一行的高度。
nonisolated enum PiRowLine: Equatable {
    case ending
    case endFailed(String)
    case draft(String)
    case progress(String)
    case hint(String)

    /// `draft` 是回复框里的草稿（`AppSettings.draftPreview`），`end` 是此刻要显示的结束请求（`DeliveryRequest.shownEnd`）。
    static func of(_ session: PiSessionState, draft: String?, end: DeliveryRequest?) -> PiRowLine? {
        if end?.isOpen == true { return .ending }
        if let reason = end?.failure { return .endFailed(reason) }
        if let draft { return .draft(draft) }
        if let progress = PiProgress.line(of: session) { return .progress(progress) }
        if session.state == .known(.settled), !session.hasStarted { return .hint("等你说第一句") }
        if session.state == .known(.incompatible) { return .hint("在终端里退出，再用 pi -c 接着") }
        return nil
    }
}

/// 会话"现在到哪了"的一句话（会话列表第三行、近况页状态块）：等你确认时是问题首行，干活时是当前动作（还没有动作时是正在处理的提问），
/// 出错时是原因首行，空闲或已结束时是最后回答的首句。先去掉 Markdown 符号再截断。没有可说的就是 nil（不占行）。
nonisolated enum PiProgress {
    static func line(of session: PiSessionState) -> String? {
        switch session.state.known {
        case .waitingForUser: firstLine(session.question?.text ?? session.detail)
        // 还没有具体动作时写正在处理的那句提问
        case .thinking, .outputting, .tool: session.detail.flatMap(action) ?? firstLine(session.pendingPrompt).map { "正在处理：\($0)" }
        case .delegating, .error: firstLine(session.detail)
        case .settled, .ended, .incompatible, nil: firstSentence(session.lastReply)
        }
    }

    /// Mac 同步来的工具详情是"工具名 · 目标"：写成"动作 目标"，如"运行 bun test"。不认识的工具照原名。
    static func action(_ detail: String) -> String? {
        let parts = detail.split(separator: " · ", maxSplits: 1).map(String.init)
        guard let tool = parts.first, !tool.isEmpty else { return nil }
        let verb = verbs[tool.lowercased()] ?? tool
        return parts.count > 1 ? "\(verb) \(parts[1])" : verb
    }

    private static let verbs = [
        "bash": "运行", "read": "读取", "edit": "修改", "write": "写入", "grep": "查找", "find": "查找", "ls": "查看",
    ]

    static func firstLine(_ text: String?) -> String? {
        // 先取原文第一个非空行再去符号：Markdown 会把相连的几行并成一段
        text?.split(whereSeparator: \.isNewline).lazy.compactMap { MarkdownBlock.plainLines(String($0)).first }.first
    }

    /// 首句：到第一个句号、问号、叹号或换行为止。
    static func firstSentence(_ text: String?) -> String? {
        guard let line = firstLine(text) else { return nil }
        guard let end = line.firstIndex(where: { "。！？!?".contains($0) }) else { return line }
        return String(line[...end])
    }
}
