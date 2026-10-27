import CueStore
import CueText
import Foundation

/// 会话"现在到哪了"的一句话（项目行、任务看板的卡、任务浮窗、会话页卡片的第二行；窄处的会话行不写它，只写状态与读数，见 `PiRowFacts`）：等你确认时是问题首行，干活时是当前动作（还没有动作时是正在处理的提问），
/// 出错时是原因首行，空闲或已结束时是最后回答的首句。先去掉 Markdown 符号再截断。没有可说的就是 nil（不占行，用的地方写状态）：
/// 没有回答时不拿最后那句提问凑数——那句可能是 Cue 发进去的，近况里分不出是谁说的，会话名已经说了是什么事。
nonisolated enum PiProgress {
    /// 任务浮窗与手机进展页大字下面的一句：没送到的原因 → 到哪了 → 新会话时的提示。
    static func note(of session: PiSessionState, failure: String?) -> String? {
        if let failure { return failure }
        if let progress = line(of: session) { return progress }
        if session.state == .known(.settled), !session.hasStarted { return String(localized: "等你说第一句") }
        return nil
    }

    static func line(of session: PiSessionState) -> String? {
        switch session.state.known {
        case .waitingForUser: firstLine(session.question?.text ?? session.detail)
        // 还没有具体动作时写正在处理的那句提问
        case .thinking, .tool: session.detail.flatMap(action) ?? firstLine(session.pendingPrompt).map { String(localized: "正在处理：\($0)") }
        case .delegating: PiSubagentLine.of(session.subagents) ?? firstLine(session.detail)
        // 状态词"正在压缩上下文"就是这一句（整页的行没有别的话时写状态词）
        case .compacting: nil
        case .error: firstLine(session.detail)
        // 被打断的：最近一轮做完的回答，正在处理的那句由状态词"被打断"带出
        case .settled, .ended, .interrupted, nil: firstSentence(session.lastReply)
        }
    }

    /// Mac 同步来的工具详情是"工具名 · 目标"：写成"动作 目标"，如"运行 bun test"。不认识的工具照原名。
    static func action(_ detail: String) -> String? {
        let parts = detail.split(separator: PiSessionState.detailSeparator, maxSplits: 1).map(String.init)
        guard let tool = parts.first, !tool.isEmpty else { return nil }
        let verb = verbs[tool.lowercased()] ?? tool
        return parts.count > 1 ? "\(verb) \(parts[1])" : verb
    }

    private static let verbs = [
        "bash": String(localized: "运行"), "read": String(localized: "读取"), "edit": String(localized: "修改"), "write": String(localized: "写入"),
        "grep": String(localized: "查找"), "find": String(localized: "查找"), "ls": String(localized: "查看"),
    ]

    static func firstLine(_ text: String?) -> String? {
        text.flatMap(MarkdownBlock.firstPlainLine)
    }

    /// Cue 页一行旁注里的一句要点（唯一的截法）：经过的每一行只写动作、名字与这一句。Cue 说的话、记忆、命令这类原文都经它——
    /// 第一行去掉开头的标签（"手机闪退：根因已查清…"：Cue 爱先写在说哪件，名字那一行已经写了），到第一个逗号、句号、分号、冒号、问号或叹号为止，
    /// 至多 `gistLimit` 个字。名字（任务、会话的标题）本身就是要点，不经它。
    static func gist(_ text: String) -> String {
        var line = Substring(firstLine(text) ?? "")
        if let colon = line.firstIndex(where: { "：:".contains($0) }), line.distance(from: line.startIndex, to: colon) <= gistLabel {
            let rest = line[line.index(after: colon)...].drop { $0.isWhitespace }
            if !rest.isEmpty { line = rest }
        }
        let clause = line.prefix { !"，,。；;：:！？!?".contains($0) }.trimmingCharacters(in: .whitespaces)
        return (clause.isEmpty ? String(line) : clause).clipped(gistLimit)
    }

    static let gistLimit = 20
    /// 冒号前至多这么多字才算标签，再长是话里的冒号
    private static let gistLabel = 12

    /// 首句：到第一个句号、问号、叹号或换行为止。
    static func firstSentence(_ text: String?) -> String? {
        guard let line = firstLine(text) else { return nil }
        guard let end = line.firstIndex(where: { "。！？!?".contains($0) }) else { return line }
        return String(line[...end])
    }
}
