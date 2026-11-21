import CueStore
import CueText
import Foundation

nonisolated enum SessionProgress {
    static func note(of session: SessionState, failure: String?) -> String? {
        if let failure { return failure }
        if let progress = line(of: session) { return progress }
        if session.runtimeState == .known(.settled), !session.hasStarted { return String(localized: "等你说第一句") }
        return nil
    }

    static func line(of session: SessionState) -> String? {
        switch session.runtimeState.known {
        case .waitingForUser: firstLine(session.question?.text ?? session.detail)
        case .thinking, .tool: session.detail.flatMap(action) ?? firstLine(session.pendingPrompt).map { String(localized: "正在处理：\($0)") }
        case .delegating: SubagentLine.of(session.runtimeSubagents) ?? firstLine(session.detail)
        case .compacting: nil
        case .error: firstLine(session.detail)
        case .settled, .ended, .interrupted, nil: firstSentence(session.lastReply)
        }
    }

    static func said(of session: SessionState) -> String? {
        switch session.runtimeState.known {
        case .thinking, .tool, .compacting: firstLine(session.pendingPrompt)
        case .delegating: SubagentLine.of(session.runtimeSubagents) ?? firstLine(session.pendingPrompt)
        case .waitingForUser, .error, .settled, .ended, .interrupted, nil: line(of: session)
        }
    }

    static func action(_ detail: String) -> String? {
        parts(detail).map { [$0.verb, $0.target].compactMap(\.self).joined(separator: " ") }
    }

    static func parts(_ detail: String) -> (verb: String, target: String?)? {
        let parts = detail.split(separator: SessionState.detailSeparator, maxSplits: 1).map(String.init)
        guard let tool = parts.first, !tool.isEmpty else { return nil }
        let verb = switch ChatMessage.Tools.Kind(tool: tool) {
        case .command: String(localized: "运行")
        case .read: String(localized: "读取")
        case .edit: String(localized: "修改")
        case .search: String(localized: "查找")
        default: tool
        }
        return (verb, parts.count > 1 ? parts[1] : nil)
    }

    static func firstLine(_ text: String?) -> String? {
        text.flatMap(MarkdownBlock.firstPlainLine)
    }

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
    private static let gistLabel = 12

    static func firstSentence(_ text: String?) -> String? {
        guard let line = firstLine(text) else { return nil }
        guard let end = line.firstIndex(where: { "。！？!?".contains($0) }) else { return line }
        return String(line[...end])
    }
}
