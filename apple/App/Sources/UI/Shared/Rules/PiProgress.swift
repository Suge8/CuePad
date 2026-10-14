import CueStore
import Foundation

/// 会话"现在到哪了"的一句话（项目行、任务行、Mac 任务面板；会话行不写它，只写状态与读数，见 `PiRowFacts`）：等你确认时是问题首行，干活时是当前动作（还没有动作时是正在处理的提问），
/// 出错时是原因首行，空闲或已结束时是最后回答的首句。先去掉 Markdown 符号再截断。没有可说的就是 nil（不占行，用的地方写状态）：
/// 没有回答时不拿最后那句提问凑数——那句可能是 Cue 发进去的，近况里分不出是谁说的，会话名已经说了是什么事。
nonisolated enum PiProgress {
    /// Mac 任务面板大字下面的一句：没送到的原因 → 到哪了 → 新会话、需要 /reload 时的提示。
    static func note(of session: PiSessionState, failure: String?) -> String? {
        if let failure { return failure }
        if let progress = line(of: session) { return progress }
        if session.state == .known(.settled), !session.hasStarted { return "等你说第一句" }
        if session.state == .known(.incompatible) { return "在终端里执行 /reload 就能接上" }
        return nil
    }

    static func line(of session: PiSessionState) -> String? {
        switch session.state.known {
        case .waitingForUser: firstLine(session.question?.text ?? session.detail)
        // 还没有具体动作时写正在处理的那句提问
        case .thinking, .outputting, .tool: session.detail.flatMap(action) ?? firstLine(session.pendingPrompt).map { "正在处理：\($0)" }
        case .delegating: PiSubagentLine.of(session.subagents) ?? firstLine(session.detail)
        // 状态词"正在压缩上下文"就是这一句（整页的行没有别的话时写状态词）
        case .compacting: nil
        case .error: firstLine(session.detail)
        // 被打断的：最近一轮做完的回答，正在处理的那句由状态词"被打断"带出
        case .settled, .ended, .interrupted, .incompatible, nil: firstSentence(session.lastReply)
        }
    }

    /// 同步数据里工具名与目标之间的分隔（Mac 写 `AppServices+Remote`、这里读）：是数据格式，不是显示用的 `Dotted`。
    static let detailSeparator = PiSessionState.detailSeparator

    /// Mac 同步来的工具详情是"工具名 · 目标"：写成"动作 目标"，如"运行 bun test"。不认识的工具照原名。
    static func action(_ detail: String) -> String? {
        let parts = detail.split(separator: Self.detailSeparator, maxSplits: 1).map(String.init)
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
