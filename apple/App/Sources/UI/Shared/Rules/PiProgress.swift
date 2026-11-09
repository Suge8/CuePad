import CueStore
import CueText
import Foundation

/// 没有回答时不拿最后那句提问凑数：那句可能是 Cue 发进去的，近况里分不出是谁说的，会话名已经说了是什么事。
nonisolated enum PiProgress {
    static func note(of session: PiSessionState, failure: String?) -> String? {
        if let failure { return failure }
        if let progress = line(of: session) { return progress }
        if session.runtimeState == .known(.settled), !session.hasStarted { return String(localized: "等你说第一句") }
        return nil
    }

    static func line(of session: PiSessionState) -> String? {
        switch session.runtimeState.known {
        case .waitingForUser: firstLine(session.question?.text ?? session.detail)
        case .thinking, .tool: session.detail.flatMap(action) ?? firstLine(session.pendingPrompt).map { String(localized: "正在处理：\($0)") }
        case .delegating: PiSubagentLine.of(session.runtimeSubagents) ?? firstLine(session.detail)
        // 状态词"正在压缩上下文"就是这一句（整页的行没有别的话时写状态词）
        case .compacting: nil
        case .error: firstLine(session.detail)
        // 被打断的：最近一轮做完的回答，正在处理的那句由状态词"被打断"带出
        case .settled, .ended, .interrupted, nil: firstSentence(session.lastReply)
        }
    }

    /// Mac 同步来的工具详情是"工具名 · 目标"。
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

    /// Cue 页一行旁注里的一句要点（唯一的截法）：Cue 说的话、记忆、命令这类原文都经它。名字（任务、会话的标题）本身就是要点，不经它。
    /// 第一行去掉开头的标签（"手机闪退：根因已查清…"：Cue 爱先写在说哪件，名字那一行已经写了）。
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

    static func firstSentence(_ text: String?) -> String? {
        guard let line = firstLine(text) else { return nil }
        guard let end = line.firstIndex(where: { "。！？!?".contains($0) }) else { return line }
        return String(line[...end])
    }
}
