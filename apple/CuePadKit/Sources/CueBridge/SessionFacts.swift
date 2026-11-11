#if os(macOS)
import CueStore
import CueText
import Foundation

/// 状态的规则只在这一处，各家把自己的事件翻译成对它的修改。歇着时压缩上下文不算新的一轮，压完计时回到压缩前。
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
    /// 在飞的后台工作（按 Agent 给的 id）：还没把结果交回主会话的子代理（Claude Code 还有后台命令）。等子代理只看它，名册只给人看。
    /// 各家只按自己的权威来源写（Claude Code 的后台任务清单、Codex 子线程的推送、OpenCode 子会话的执行状态）。
    /// 做完了的在主会话为它开始新的一轮（Agent 自己开，或接入补开）之前仍在飞：歇下只在那一轮做完之后，一件事只歇下一次。
    var inFlight: Set<String> = []
    private(set) var turnStartedAt: Date?
    private(set) var subagents: [(id: String, state: SubagentState)] = []
    private var beforeCompaction: (since: Date, busySince: Date?)?

    /// 开始新的一轮。`start` 要早于这一轮在会话文件里可能的收尾（歇下就绪看收尾不早于它，`SessionState.answered`）：
    /// 取 Agent 给的开始时刻；没有就取一定在它之前的——挡住这一轮的钩子、CuePad 发出话或空输入、收到开始通知的那一刻；
    /// 接上时已在跑的取拿到列表或快照之后会话记录里最后一轮的开始（`HistoryCheckpoint.lastTurnStart`）：接上的此刻、请求前的时刻、
    /// 库里旧的都分不清期间换没换轮（会晚于这一轮的收尾或早于上一轮的回答），记录里一轮都读不到才取请求前的时刻。
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

    /// 子代理开始一次运行：第一次是新的一项；同一 id 再跑（Claude Code 被自己名下的后台命令叫醒、Codex 的 followup）名册里还是那一项，
    /// 回到在跑，从此刻重新算（同 FireCode 名册的"本次运行"）。
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
        session.question = question
        let roster = subagents.map(\.state)
        if session.subagents != roster { session.subagents = roster }
    }
}

extension Session {
    /// 与 Pi 扩展的计时同一规则。
    mutating func enter(_ next: WorkState, detail: String? = nil, at now: Date = .now) {
        if next.phase != state.phase { stateSince = now }
        busySince = next.isWorking || next == .waitingForUser ? busySince ?? now : nil
        if next != .error { errorMessage = nil }
        state = next
        self.detail = detail
    }
}

/// 同 Pi 扩展，各家共用。
enum ToolDetail {
    static let limit = 120

    static func line(_ tool: String, _ input: JSONValue?) -> String {
        guard let target = target(input) else { return name(tool).clipped(limit) }
        return (name(tool) + SessionState.detailSeparator + target).clipped(limit)
    }

    /// 给人看的工具名：MCP 工具（`mcp__<服务>__<工具>`，Claude Code 与 Codex 的写法）照 Claude Code 终端写成"服务 - 工具 (MCP)"；
    /// Codex 钩子里命名空间下的内置工具是命名空间直接拼工具名（`clock` 与 `sleep` 成了 `clocksleep`，同 MCP 的 `mcp__<服务>__` 拼工具名），
    /// 写回 Codex 自己的写法（`clock.sleep`）。
    static func name(_ tool: String) -> String {
        if let namespaced = codexNamespaced[tool] { return namespaced }
        let prefix = "mcp__"
        guard tool.hasPrefix(prefix), let split = tool.dropFirst(prefix.count).range(of: "__") else { return tool }
        let rest = tool.dropFirst(prefix.count)
        return "\(rest[..<split.lowerBound]) - \(rest[split.upperBound...]) (MCP)"
    }

    private static let codexNamespaced = Dictionary(uniqueKeysWithValues: ["clock.sleep", "image_gen.generation", "web.search"].map {
        ($0.replacingOccurrences(of: ".", with: ""), $0)
    })

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

/// 挂在钩子上、要你回答的（Codex 的权限确认、Claude Code 的 `AskUserQuestion` 与 MCP 请求输入）在哪里答：按人在不在这台 Mac 前（`UserPresence`）。
/// 人在就当场放行钩子，Agent 在自己的终端界面里问，CuePad 只显示；人不在就挂住等 CuePad 作答，挂住期间人回来了就放行、终端补问。
/// 后台托管的会话没有终端，不经这里（总是挂住）。
@MainActor
final class PresenceGate {
    private let presence: any UserPresence
    private var held: [UUID: @MainActor () -> Void] = [:]
    private var watch: Task<Void, Never>?

    init(presence: any UserPresence) {
        self.presence = presence
    }

    /// 人在返回 nil（调用方放行钩子、只显示）；人不在就挂住，人回来时调 `handBack`（调用方放行钩子、改成只显示），返回挂住的凭据：
    /// 答过、被收回、会话下线时 `drop`。
    func hold(handBack: @escaping @MainActor () -> Void) -> UUID? {
        guard !presence.isPresent else { return nil }
        let token = UUID()
        held[token] = handBack
        if watch == nil {
            watch = Task { [weak self, presence] in
                await presence.untilPresent()
                guard let self, !Task.isCancelled else { return }
                let all = self.held.values
                self.held = [:]
                self.watch = nil
                for handBack in all { handBack() }
            }
        }
        return token
    }

    func drop(_ token: UUID?) {
        guard let token, held.removeValue(forKey: token) != nil, held.isEmpty else { return }
        watch?.cancel()
        watch = nil
    }
}

/// 作答时回给模型的原因说明是用户在 CuePad 里答的（不说成 CuePad 自己拦的）。各家同一句式。
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
