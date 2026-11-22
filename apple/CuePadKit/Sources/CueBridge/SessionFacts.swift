#if os(macOS)
import CueStore
import CueText
import Foundation

struct SessionFacts {
    var running = false
    var activity: WorkState = .thinking
    var activityDetail: String?
    var questions: [Question] = []
    /// 不挡着这一轮的提问（Codex 的 `request_user_input_async`）：Agent 问完照常做事或歇下，你说了下一句（答案就是这句话）才收起，
    /// 这一轮结束不作废；在等它时也算等你回答
    var standingQuestion: Question?
    var compacting = false
    var failure: String?
    var inFlight: Set<String> = []
    private(set) var turnStartedAt: Date?
    var turnOpener: TurnOpener?
    private(set) var subagents: [(id: String, state: SubagentState)] = []
    private var beforeCompaction: (since: Date, busySince: Date?)?

    mutating func startTurn(at start: Date) {
        turnStartedAt = start
        running = true
        work(.thinking)
        failure = nil
    }

    mutating func endTurn(failure: String? = nil) {
        running = false
        work(.thinking)
        questions = []
        self.failure = failure
    }

    mutating func work(_ activity: WorkState, detail: String? = nil) {
        self.activity = activity
        activityDetail = detail
    }

    mutating func startSubagent(_ id: String, name: String, role: String, at now: Date) {
        subagents.append((id, SubagentState(name: name.isEmpty ? role : name, role: role, phase: .known(.running), startedAt: now, progressAt: now)))
    }

    mutating func runSubagent(_ id: String, name: String, role: String, at now: Date) {
        guard subagents.contains(where: { $0.id == id }) else { return startSubagent(id, name: name, role: role, at: now) }
        updateSubagent(id, at: now) { agent in
            (agent.phase, agent.action, agent.startedAt, agent.settledAt) = (.known(.running), "", now, nil)
        }
    }

    /// 不在名册里的不管（如压缩上下文也会报一个没有开始的子代理）；改出了变化就是它在 `now` 有进展。
    mutating func updateSubagent(_ id: String, at now: Date, _ change: (inout SubagentState) -> Void) {
        guard let index = subagents.lastIndex(where: { $0.id == id }) else { return }
        let before = subagents[index].state
        change(&subagents[index].state)
        if subagents[index].state != before { subagents[index].state.progressAt = now }
    }

    mutating func settleSubagent(_ id: String, _ phase: SubagentPhase, summary: String?, at now: Date) {
        updateSubagent(id, at: now) { agent in
            agent.phase = .known(phase)
            agent.action = summary.flatMap(\.firstLine).map { $0.clipped(ToolDetail.limit) } ?? ""
            agent.settledAt = now
        }
    }

    var state: (state: WorkState, detail: String?) {
        if let question { return (.waitingForUser, ToolDetail.singleLine(question.text).clipped(ToolDetail.limit)) }
        if compacting { return (.compacting, nil) }
        if running { return (activity, activityDetail) }
        if !inFlight.isEmpty { return (.delegating, nil) }
        if let failure { return (.error, ErrorSummary(failure).line) }
        return (.settled, nil)
    }

    var question: Question? { questions.first ?? standingQuestion }

    mutating func publish(to session: inout Session, at now: Date = .now) {
        let (state, detail) = state
        if state == .compacting, session.state != .compacting, !session.state.hasPendingWork {
            beforeCompaction = (session.stateSince, session.busySince)
        }
        session.enter(state, detail: detail, at: now)
        if state != .compacting, let before = beforeCompaction {
            beforeCompaction = nil
            if !state.isWorking, state != .waitingForUser {
                session.stateSince = before.since
                session.busySince = before.busySince
            }
        }
        if state == .error { session.errorMessage = failure }
        session.turnStartedAt = turnStartedAt
        session.turnOpener = turnOpener
        session.question = question
        let roster = subagents.map(\.state)
        if session.subagents != roster { session.subagents = roster }
    }
}

extension Session {
    mutating func enter(_ next: WorkState, detail: String? = nil, at now: Date = .now) {
        if next.phase != state.phase { stateSince = now }
        busySince = next.isWorking || next == .waitingForUser ? busySince ?? now : nil
        if next != .error { errorMessage = nil }
        state = next
        self.detail = detail
    }
}

enum ToolDetail {
    static let limit = 120

    static func line(_ tool: String, _ input: JSONValue?) -> String {
        guard let target = target(input) else { return name(tool).clipped(limit) }
        return (name(tool) + SessionState.detailSeparator + target).clipped(limit)
    }

    /// 给人看的工具名：MCP 工具（`mcp__<服务>__<工具>`，Claude Code 与 Codex 的写法）照 Claude Code 终端写成"服务 - 工具 (MCP)"。
    static func name(_ tool: String) -> String {
        let prefix = "mcp__"
        guard tool.hasPrefix(prefix), let split = tool.dropFirst(prefix.count).range(of: "__") else { return tool }
        let rest = tool.dropFirst(prefix.count)
        return "\(rest[..<split.lowerBound]) - \(rest[split.upperBound...]) (MCP)"
    }

    static func line(_ tool: String, _ arguments: ToolArguments?) -> String {
        line(tool, arguments.map { arguments -> JSONValue in
            var object: [String: JSONValue] = [:]
            if let command = arguments.command { object["command"] = .string(command) }
            if let pattern = arguments.pattern { object["pattern"] = .string(pattern) }
            if let path = arguments.path { object["path"] = .string(path) }
            return .object(object)
        })
    }

    static func target(_ input: JSONValue?) -> String? {
        let line = ["command", "pattern", "query", "url", "description"].lazy.compactMap { input?[$0]?.string }.first.flatMap(\.firstLine)
        let file = (input?["file_path"]?.string ?? input?["path"]?.string ?? input?["notebook_path"]?.string).map { URL(filePath: $0).lastPathComponent }
        return line ?? file
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: SessionState.detailSeparator)
    }

}

enum PermissionWording {
    static let allowed = "用户在 CuePad 里允许了", denied = "用户在 CuePad 里拒绝了"

    static func question(_ agent: AgentKind, _ action: String, _ details: [String?]) -> String {
        let lines = ([String(localized: "允许 \(agent.name) \(action)？")] + details.compactMap { $0 }).reduce(into: [String]()) { lines, line in
            if !line.isEmpty, !lines.contains(line) { lines.append(line) }
        }
        return lines.joined(separator: "\n").clipped(500)
    }
}
#endif
