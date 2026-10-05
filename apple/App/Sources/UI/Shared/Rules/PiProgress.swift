import CueStore
import Foundation

/// 会话"现在到哪了"的一句话（会话列表第三行、近况页状态块）：等你确认时是问题首行，干活时是当前动作，
/// 出错时是原因首行，空闲或已结束时是最后回答的首句。先去掉 Markdown 符号再截断。没有可说的就是 nil（不占行）。
nonisolated enum PiProgress {
    static func line(of session: PiSessionState) -> String? {
        switch session.state.known {
        case .waitingForUser: firstLine(session.question?.text ?? session.detail)
        case .thinking, .outputting, .tool: session.detail.flatMap(action)
        case .delegating, .error: firstLine(session.detail)
        case .settled, .ended, nil: firstSentence(session.lastReply)
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
        text.flatMap { MarkdownBlock.plainLines($0).first }
    }

    /// 首句：到第一个句号、问号、叹号或换行为止。
    static func firstSentence(_ text: String?) -> String? {
        guard let line = firstLine(text) else { return nil }
        guard let end = line.firstIndex(where: { "。！？!?".contains($0) }) else { return line }
        return String(line[...end])
    }
}
