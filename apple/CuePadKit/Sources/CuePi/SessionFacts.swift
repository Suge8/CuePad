#if os(macOS)
import CueStore
import Foundation

/// 一个会话此刻的事实：各家把自己的事件（钩子、stream-json、app-server 通知、服务事件）翻译成对它的修改，桥上的状态、那句说明、
/// 要你回答的、子代理与出错原文都由它推出（`publish`）。状态的规则只在这一处：
/// 要你回答的优先；在压缩；自己这一轮在跑就看在做什么；歇下了还有子代理在跑是等子代理；上一轮出错是出错；否则空闲。
/// 计时与 Pi 扩展同一规则（`PiSession.enter`）；歇着时压缩上下文不算新的一轮，压完计时回到压缩前。
struct SessionFacts {
    /// 自己这一轮在跑（子代理不算）
    var running = false
    /// 在跑时在做什么（思考、输出、调工具）与那句说明
    var activity: PiWorkState = .thinking
    var activityDetail: String?
    /// 要你回答的，按到达先后；显示第一个
    var questions: [PiQuestion] = []
    var compacting = false
    /// 上一轮出错的原文；开始新的一轮时清掉
    var failure: String?
    /// 子代理名册（按 Agent 给的 id），按出现先后
    private(set) var subagents: [(id: String, state: PiSubagentState)] = []
    /// 歇着时开始压缩那一刻的计时：压完回到它
    private var beforeCompaction: (since: Date, busySince: Date?)?

    /// 开始新的一轮。
    mutating func startTurn() {
        running = true
        work(.thinking)
        failure = nil
    }

    /// 这一轮结束（`failure` 是出错的原文）：要你回答的随之作废。
    mutating func endTurn(failure: String? = nil) {
        running = false
        work(.thinking)
        questions = []
        self.failure = failure
    }

    /// 在跑时换成在做 `activity`（思考、输出、调工具）。
    mutating func work(_ activity: PiWorkState, detail: String? = nil) {
        self.activity = activity
        activityDetail = detail
    }

    var hasRunningSubagent: Bool { subagents.contains { $0.state.phase == .known(.running) } }

    mutating func startSubagent(_ id: String, name: String, role: String, at now: Date) {
        subagents.append((id, PiSubagentState(name: name.isEmpty ? role : name, role: role, phase: .known(.running), startedAt: now)))
    }

    /// 改一个子代理（不在名册里的不管：如压缩上下文也会报一个没有开始的子代理）。
    mutating func updateSubagent(_ id: String, _ change: (inout PiSubagentState) -> Void) {
        guard let index = subagents.lastIndex(where: { $0.id == id }) else { return }
        change(&subagents[index].state)
    }

    /// 子代理歇下：那句说明是它最后的话的首行。
    mutating func settleSubagent(_ id: String, _ phase: PiSubagentPhase, summary: String?, at now: Date) {
        updateSubagent(id) { agent in
            agent.phase = .known(phase)
            agent.action = summary.flatMap(ToolDetail.firstLine).map { ToolDetail.clip($0) } ?? ""
            agent.settledAt = now
        }
    }

    /// 此刻的状态与那句说明。
    var state: (state: PiWorkState, detail: String?) {
        if let question = questions.first { return (.waitingForUser, ToolDetail.clip(ToolDetail.singleLine(question.text))) }
        if compacting { return (.compacting, nil) }
        if running { return (activity, activityDetail) }
        if hasRunningSubagent { return (.delegating, nil) }
        if let failure { return (.error, PiErrorSummary(failure).line) }
        return (.settled, nil)
    }

    /// 把事实写进桥上的会话。
    mutating func publish(to session: inout PiSession, at now: Date = .now) {
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
        session.question = questions.first
        let roster = subagents.map(\.state)
        if session.subagents != roster { session.subagents = roster }
    }
}

extension PiSession {
    /// 进入 `next`：粗状态（`PiWorkState.phase`）变了才换 `stateSince`；离开空闲起记 `busySince`，
    /// 中间等你确认不断，歇下、出错时清掉。与 Pi 扩展的计时同一规则。
    mutating func enter(_ next: PiWorkState, detail: String? = nil, at now: Date = .now) {
        if next.phase != state.phase { stateSince = now }
        busySince = next.isWorking || next == .waitingForUser ? busySince ?? now : nil
        if next != .error { errorMessage = nil }
        state = next
        self.detail = detail
    }
}

/// 正在做的事写成一句话（同 Pi 扩展）："工具名 · 目标"：命令、搜索、网址取首个非空行，文件取文件名，至多 120 字。三家共用。
enum ToolDetail {
    static let limit = 120

    static func line(_ tool: String, _ input: JSONValue?) -> String {
        guard let target = target(input) else { return clip(tool) }
        return clip(tool + PiSessionState.detailSeparator + target)
    }

    static func line(_ tool: String, _ arguments: PiToolArguments?) -> String {
        line(tool, arguments.map { arguments -> JSONValue in
            var object: [String: JSONValue] = [:]
            if let command = arguments.command { object["command"] = .string(command) }
            if let pattern = arguments.pattern { object["pattern"] = .string(pattern) }
            if let path = arguments.path { object["path"] = .string(path) }
            return .object(object)
        })
    }

    /// 调用的目标：命令、搜索、网址、说明取首个非空行，文件取文件名。
    static func target(_ input: JSONValue?) -> String? {
        let line = ["command", "pattern", "query", "url", "description"].lazy.compactMap { input?[$0]?.string }.first.flatMap(firstLine)
        let file = (input?["file_path"]?.string ?? input?["path"]?.string ?? input?["notebook_path"]?.string).map { URL(filePath: $0).lastPathComponent }
        return line ?? file
    }

    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// 多行并成一行（行之间用说明的分隔符）。
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: PiSessionState.detailSeparator)
    }

    static func clip(_ text: String, _ limit: Int = limit) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

/// 挂在钩子上、要你回答的（Codex 的权限确认、Claude Code 的 `AskUserQuestion` 与 MCP 请求输入）在哪里答：按人在不在这台 Mac 前（`UserPresence`）。
/// 人在就当场放行钩子，Agent 在自己的终端界面里问，CuePad 只显示；人不在就挂住等 CuePad 作答，挂住期间人回来了就放行、终端补问。
/// 后台托管的会话没有终端，不经这里（总是挂住）。
@MainActor
final class PresenceGate {
    private let presence: any UserPresence
    /// 挂住的：人回来时放行
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
#endif
