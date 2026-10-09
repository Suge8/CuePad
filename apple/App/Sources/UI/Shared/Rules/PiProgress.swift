import CueStore
import Foundation

/// 会话行名字下面那一句（全 App 的会话行同一条，`PiSessionRow`）：结束请求的进度 → 没送到的原因 → 回复框里没发的草稿 → 到哪了（`PiProgress`）→ 新会话的提示。
/// 什么都没有时是 nil；整页的行这时写状态词（`lead`），窄处的行状态词本来就在前面。
/// 已结束的会话第二层只写它做了什么（见 `PiProgress`），状态只由带斜线的状态标表达：翻历史时不满屏"已结束"。
/// 没有记下回答也没有你说的话（Mac 从会话文件回填的旧历史常常只有名字，名字本身就是第一句提问）时这一层空着。
nonisolated enum PiRowLine: Equatable {
    case ending
    case endFailed(String)
    /// 你看过之前一直写着的没送到的原因（没送到的话、没改成的名字）。
    case failed(String)
    case draft(String)
    case progress(String)
    case hint(String)
    /// 没有更要紧的一句时，整页的行写状态词（`PiShown.label`）。
    case status(String)

    /// 读屏念的那一句（行上显示的文字去掉着色、强调）。
    var speech: String {
        switch self {
        case .ending: "正在结束…"
        case .endFailed(let text), .failed(let text), .progress(let text), .hint(let text), .status(let text): text
        case .draft(let draft): "草稿 \(draft)"
        }
    }

    /// `draft` 是回复框里的草稿（`AppSettings.draftPreview`），`end` 是此刻要显示的结束请求（`DeliveryRequest.shownEnd`）。
    /// `failure` 是此刻要写的没送到的原因（`PiRename.failure` 或显示为没能送达的那条话的原因）。
    static func of(_ session: PiSessionState, draft: String?, end: DeliveryRequest?, failure: String? = nil) -> PiRowLine? {
        if end?.isOpen == true { return .ending }
        if let reason = end?.failure { return .endFailed(reason) }
        if let failure { return .failed(failure) }
        if let draft { return .draft(draft) }
        if let progress = PiProgress.line(of: session) { return .progress(progress) }
        if session.state == .known(.settled), !session.hasStarted { return .hint("等你说第一句") }
        if session.state == .known(.incompatible) { return .hint("在终端里执行 /reload 就能接上") }
        return nil
    }

    /// 整页的行名字下面只有这一句：等你确认时是问题、出错时是原因、工作中是在做什么，状态由状态标表达；没有这样一句时才写状态词，
    /// 已结束的除外（nil：这一层空着）。
    static func lead(_ session: PiSessionState, shown: PiShown, draft: String?, end: DeliveryRequest?, failure: String? = nil) -> PiRowLine? {
        of(session, draft: draft, end: end, failure: failure) ?? (session.state == .known(.ended) ? nil : .status(shown.label))
    }
}

/// 会话"现在到哪了"的一句话（会话列表第三行、近况页状态块）：等你确认时是问题首行，干活时是当前动作（还没有动作时是正在处理的提问），
/// 出错时是原因首行，空闲或已结束时是最后回答的首句、没有回答时是你最后说的那句（"你：…"）。先去掉 Markdown 符号再截断。没有可说的就是 nil（不占行）。
nonisolated enum PiProgress {
    static func line(of session: PiSessionState) -> String? {
        switch session.state.known {
        case .waitingForUser: firstLine(session.question?.text ?? session.detail)
        // 还没有具体动作时写正在处理的那句提问
        case .thinking, .outputting, .tool: session.detail.flatMap(action) ?? firstLine(session.pendingPrompt).map { "正在处理：\($0)" }
        case .delegating: PiSubagentLine.of(session.subagents) ?? firstLine(session.detail)
        case .error: firstLine(session.detail)
        case .settled, .ended, .incompatible, nil: firstSentence(session.lastReply) ?? firstLine(session.lastPrompt).map { "你：\($0)" }
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
        text.flatMap(MarkdownBlock.firstPlainLine)
    }

    /// 首句：到第一个句号、问号、叹号或换行为止。
    static func firstSentence(_ text: String?) -> String? {
        guard let line = firstLine(text) else { return nil }
        guard let end = line.firstIndex(where: { "。！？!?".contains($0) }) else { return line }
        return String(line[...end])
    }
}
