#if os(macOS)
import CueStore
import CueText
import Darwin
import Foundation

/// 终端里跑的一个 Claude Code 会话：状态由钩子推出（`ClaudeCodeRuntime` 把这个会话的每次钩子调用交给 `handle`），
/// 一轮从 `UserPromptSubmit` 起到 `Stop` 止。在飞的工作只认 `Stop` 带的后台任务清单（`background_tasks`：后台子代理与后台命令，
/// 做完了还没交回的也在）：后台任务做完时 Claude Code 自己开一轮交回结果（`UserPromptSubmit` 的正文是 `<task-notification>`），
/// 所以清单只在一轮结束时换，其间等子代理照旧，直到交回结果的那一轮做完。`SubagentStart`/`SubagentStop` 只改名册：
/// 被停下的子代理没有 `SubagentStop`，下一个 `Stop` 的清单里没有它就记成被停下。
/// 说话经它的收件箱 socket，结束是给进程发 SIGINT（与在终端里按 Ctrl-C 退出同一条路：跑 `SessionEnd` 钩子、恢复终端），
/// 改名经收件箱的 `rename`。做不到的（图片、停止这一轮、换模型与强度、斜杠命令）见 `AgentCapabilities`，桥先拒绝。
/// 收件箱送到的话 Claude Code 一律当作"另一个会话发来的"（包上同伴消息的说明；行里没有能改这一点的字段，实测 2.1.299），
/// 所以正文前带一句 `ClaudeInbox.userNote`：是用户本人从 CuePad 发的，直接回答、不必回传。模型仍可能把它当同伴请求看待。
///
/// 要你回答的：
/// - 权限确认经挡着的 `PermissionRequest` 钩子，终端里同时弹框，哪边先答算哪边；
/// - 提问（`AskUserQuestion`）经 `PreToolUse` 钩子（官方的路：放行并改写输入里的 `answers`），MCP 请求输入经 `Elicitation` 钩子：
///   挂住钩子时终端不弹，所以按人在不在（`PresenceGate`）分：人在就放行、终端里问，CuePad 只显示；人不在就挂住等 CuePad 答，人回来就放行。
@MainActor
final class ClaudeTerminalSession: SessionLink {
    let id: PiSession.ID
    let pid: Int32
    private weak var bridge: PiBridge?
    private let gate: PresenceGate
    /// 收件箱 socket（钩子环境里的 `CLAUDE_CODE_MESSAGING_SOCKET`，或会话登记文件里的）
    var inbox: String?
    /// 收件箱令牌（钩子环境里的 `CLAUDE_CODE_MESSAGING_TOKEN`）：没有它，跳过权限确认的会话把送来的话挂起等你批准
    var inboxToken: String?
    private var facts = SessionFacts()
    /// 要你回答的（同一时刻可能有好几个：子代理并行时各自要确认），按到达先后；会话的 `question` 是第一个
    private var pending: [Pending] = []

    private struct Pending {
        var question: PiQuestion
        var kind: Kind
        /// 挂着的钩子；交给终端了（放行了）为 nil，这时只显示
        var call: AgentHookCall?
        /// 主会话为 nil，子代理是它的 `agent_id`
        var agent: String?
        /// 人不在而挂住（`PresenceGate`）
        var hold: UUID?

        enum Kind {
            case permission(ClaudePermission)
            case ask(ClaudePermission)
            /// 只有一个字段的表单（字段名、类型、可选值）
            case elicitation(field: String, type: String, values: [String]?)
        }
    }

    /// - Parameter runningSince: 接上时已在跑（在忙或在等你）：这一轮的开始取不晚于看到它在跑的时刻（`SessionFacts.startTurn(at:)`）
    init(id: PiSession.ID, pid: Int32, bridge: PiBridge, gate: PresenceGate, inbox: String?, runningSince: Date?, waiting: Bool) {
        self.id = id
        self.pid = pid
        self.bridge = bridge
        self.gate = gate
        self.inbox = inbox
        if let runningSince { facts.startTurn(at: runningSince) }
        if waiting { facts.questions = [PiQuestion(promptID: nil, kind: .unknown("terminal"), text: "在终端里等你")] }
    }

    /// 补上桥时按事实写好的会话。
    func publish(_ session: inout PiSession) { facts.publish(to: &session) }

    // MARK: 钩子

    /// 一次钩子调用：更新会话；要等答复的留着，其余当场放行。
    func handle(_ event: String, _ input: JSONValue, call: AgentHookCall) {
        let agent = input["agent_id"]?.string
        let now = Date.now
        // 在等的之后同一个代理又有了动静：终端里已经答了（Claude Code 不收回挡着的钩子），不再等
        if event != "PermissionRequest" { settlePending(agent: agent, when: event) }
        bridge?.update(id) { session in
            if let level = input["effort"]?["level"]?.string { session.thinking = Open(rawValue: level) }
            if let title = input["session_title"]?.string, !title.isEmpty { session.name = title }
            if session.firstMessage == nil, event == "UserPromptSubmit", let prompt = input["prompt"]?.string, !prompt.isEmpty {
                session.firstMessage = String(prompt.prefix(PiSessionName.firstMessageLimit))
            }
            if event == "PostModelSwitch", let model = input["to_model"]?.string { session.model = ClaudeCode.model(model) }
        }
        let tool = input["tool_name"]?.string ?? "?"
        switch event {
        case "UserPromptSubmit":
            facts.startTurn(at: now)  // 钩子挡着这一句：收到它一定早于这一轮的回答
        case "PreToolUse" where tool == "AskUserQuestion":
            let ask = ClaudePermission(tool: tool, input: input["tool_input"] ?? .object([:]))
            return hold(Pending(question: ask.question(), kind: .ask(ask), call: call, agent: agent), answerable: ask.answerable, at: now)
        case "PreToolUse":
            if let agent {
                facts.updateSubagent(agent, at: now) { $0.action = ToolDetail.line(tool, input["tool_input"]) }
            } else {
                facts.work(.tool, detail: ToolDetail.line(tool, input["tool_input"]))
            }
        case "PostToolUse", "PostToolUseFailure":
            if agent == nil { facts.work(.thinking) }
        case "PermissionRequest" where tool == "AskUserQuestion":
            break  // 提问在 PreToolUse 里答
        case "PermissionRequest":
            let permission = ClaudePermission(tool: tool, input: input["tool_input"] ?? .object([:]))
            pending.append(Pending(question: permission.question(), kind: .permission(permission), call: call, agent: agent))
            watch(call, promptID: permission.promptID)
            return show(at: now)
        case "Elicitation":
            return elicit(input, call: call, agent: agent, at: now)
        case "Stop":
            facts.endTurn()
            inFlight(input["background_tasks"], at: now)
        case "StopFailure":
            facts.endTurn(failure: ClaudeCode.failure(
                code: input["error"]?.string ?? "unknown", details: input["error_details"]?.string, message: input["last_assistant_message"]?.string))
            inFlight(input["background_tasks"], at: now)
        case "PreCompact":
            facts.compacting = true
        case "PostCompact":
            facts.compacting = false
        case "SubagentStart":
            if let agent { facts.runSubagent(agent, name: "", role: input["agent_type"]?.string ?? "", at: now) }
        case "SubagentStop":
            // 压缩上下文也会报一个没有开始的子代理，不在名册里
            if let agent { facts.settleSubagent(agent, .done, summary: input["last_assistant_message"]?.string, at: now) }
        default:
            break
        }
        call.finish()
        show(at: now)
    }

    /// 一轮结束时的后台任务清单就是在飞的工作；名册里还在跑却不在清单里的是被停下了。没带清单的（`StopFailure` 文档里没有这一项）不动。
    private func inFlight(_ tasks: JSONValue?, at now: Date) {
        guard let tasks = tasks?.array else { return }
        facts.inFlight = Set(tasks.compactMap { $0["id"]?.string })
        for (agent, state) in facts.subagents where state.phase == .known(.running) && !facts.inFlight.contains(agent) {
            facts.settleSubagent(agent, .interrupted, summary: nil, at: now)
        }
    }

    /// MCP 服务请求输入（`Elicitation`）：只有一个字段的表单（文字、选项、是否）能从 CuePad 答，其余（多个字段、要打开网址）只显示。
    private func elicit(_ input: JSONValue, call: AgentHookCall, agent: String?, at now: Date) {
        let message = input["message"]?.string ?? ""
        let text = [input["mcp_server_name"]?.string, message].compactMap { $0 }.joined(separator: "\n").clipped(500)
        let properties = input["requested_schema"]?["properties"]?.object ?? [:]
        guard input["mode"]?.string ?? "form" == "form", properties.count == 1, let (field, schema) = properties.first,
              let type = schema["type"]?.string, ["string", "boolean"].contains(type) else {
            let question = PiQuestion(promptID: nil, kind: .unknown("elicitation"), text: text)
            return hold(Pending(question: question, kind: .elicitation(field: "", type: "", values: nil), call: call, agent: agent), answerable: false, at: now)
        }
        let values = schema["enum"]?.array?.compactMap(\.string)
        let kind: PiQuestionKind = type == "boolean" ? .confirm : values?.isEmpty == false ? .select : .text
        let title = [schema["title"]?.string ?? schema["description"]?.string].compactMap { $0 }
        let question = PiQuestion(promptID: UUID().uuidString, kind: kind, text: ([text] + title).joined(separator: "\n"), options: values ?? [])
        hold(Pending(question: question, kind: .elicitation(field: field, type: type, values: values), call: call, agent: agent), answerable: true, at: now)
    }

    /// 挂住钩子会让终端不问：人不在才挂住等 CuePad 答，人在（或 CuePad 答不了）就放行，终端里问，CuePad 只显示。
    private func hold(_ item: Pending, answerable: Bool, at now: Date) {
        var item = item
        let promptID = item.question.promptID
        if answerable, let promptID, let token = gate.hold(handBack: { [weak self] in self?.handBack(promptID) }) {
            item.hold = token
            watch(item.call, promptID: promptID)
        } else {
            item.call?.finish()
            item.call = nil
            item.question.promptID = nil
        }
        pending.append(item)
        show(at: now)
    }

    /// 人回来了：放行，终端里问，CuePad 里只显示。
    private func handBack(_ promptID: String) {
        guard let index = pending.firstIndex(where: { $0.question.promptID == promptID }) else { return }
        pending[index].call?.finish()
        pending[index].call = nil
        pending[index].hold = nil
        pending[index].question.promptID = nil
        show(at: .now)
    }

    /// 钩子进程先走了（超时、Claude Code 收回）：问题不再等。
    private func watch(_ call: AgentHookCall?, promptID: String) {
        call?.onClose = { [weak self] in self?.withdraw(promptID) }
    }

    /// 进程退出或会话结束：还挂着的钩子放掉（进程走了它们也就没了）。
    func close() {
        for item in pending {
            item.call?.finish()
            gate.drop(item.hold)
        }
        pending = []
    }

    private func show(at now: Date) {
        facts.questions = pending.map(\.question)
        bridge?.update(id) { facts.publish(to: &$0, at: now) }
    }

    /// 终端里先答了：同一个代理之后的任一事件说明它已不在等；这一轮结束时全部作废。
    private func settlePending(agent: String?, when event: String) {
        let ending = event == "Stop" || event == "StopFailure"
        let stale = pending.filter { $0.agent == agent || ending }
        guard !stale.isEmpty else { return }
        for item in stale {
            item.call?.finish()
            gate.drop(item.hold)
        }
        pending.removeAll { item in ending || item.agent == agent }
    }

    private func withdraw(_ promptID: String) {
        guard let index = pending.firstIndex(where: { $0.question.promptID == promptID }) else { return }
        gate.drop(pending.remove(at: index).hold)
        show(at: .now)
    }

    // MARK: SessionLink

    func send(_ message: PiMessage) async throws -> PiDelivery {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PiBridgeError.rejected("empty") }
        guard let session = bridge?.session(id: id) else { throw PiBridgeError.sessionEnded }
        let busy = session.state.isTurnRunning
        let mode = message.whenBusy ?? .followUp
        // 收件箱的 now 等在跑的工具做完、在这一轮里插进去（马上说），later 等这一轮做完（等它做完再说）
        var line: [String: JSONValue] = [
            "type": "user", "message": ["role": "user", "content": .string(ClaudeInbox.userNote + message.text)],
            "priority": .string(!busy ? "next" : mode == .steer ? "now" : "later"),
        ]
        if let delivery = message.deliveryID { line["uuid"] = .string(delivery) }
        try await post(.object(line))
        return busy ? .queued(mode) : .immediate
    }

    func command(_ line: String, whenBusy: PiQueueMode?) async throws { throw PiBridgeError.unsupported }
    func abort() async throws { throw PiBridgeError.unsupported }

    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws {
        guard let name else { throw PiBridgeError.unsupported }
        try await post(["type": "control", "action": "rename", "name": .string(name)])
        bridge?.update(id) { $0.name = name }
    }

    func answer(_ answer: PiAnswerValue, to promptID: String) async throws {
        guard let index = pending.firstIndex(where: { $0.question.promptID == promptID }), let call = pending[index].call else {
            throw PiBridgeError.rejected(pending.contains { $0.call != nil } ? "stale_prompt" : "no_prompt")
        }
        let output: JSONValue = switch pending[index].kind {
        case .permission(let permission):
            ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": try permission.decision(answer, to: promptID)]]
        case .ask(let ask):
            ["hookSpecificOutput": [
                "hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": try ask.answered(answer, to: promptID),
            ]]
        case .elicitation(let field, let type, let values):
            ["hookSpecificOutput": ["hookEventName": "Elicitation", "action": "accept", "content": [field: try Self.value(answer, type, values)]]]
        }
        call.reply(output.data + Data([0x0A]))
        gate.drop(pending.remove(at: index).hold)
        show(at: .now)
    }

    /// 表单字段的值：选项按显示的原文认。
    private static func value(_ answer: PiAnswerValue, _ type: String, _ values: [String]?) throws -> JSONValue {
        switch (answer, type) {
        case (.confirmed(let yes), "boolean"): return .bool(yes)
        case (.option(let label), "string") where values?.contains(label) == true: return .string(label)
        case (.text(let text), "string") where values?.isEmpty != false: return .string(text)
        default: throw PiBridgeError.rejected("bad_answer")
        }
    }

    func end() async throws {
        guard kill(pid, SIGINT) == 0 else { throw PiBridgeError.sessionEnded }
    }

    private func post(_ line: JSONValue) async throws {
        guard let inbox else { throw PiBridgeError.unsupported }
        var lines = Data()
        if let inboxToken { lines += (["type": "auth", "token": .string(inboxToken)] as JSONValue).data + [0x0A] }
        lines += line.data + [0x0A]
        try await ClaudeInbox.post(lines, to: inbox)
    }
}

/// Claude Code 会话的收件箱（跨会话消息的 Unix socket，2.1.224 起，官方文档化）：连上、写几行、关掉。它不回话。
/// 第一行可以是认证行 `{"type": "auth", "token": …}`（官方给"脚本往自己会话里投递"的路）：macOS 上不要求，但带上了，
/// 跳过权限确认的会话才直接收下，不挂起等你批准。消息体的格式（`{"type": "user" | "control", …}`）官方没有写，来自实测。
enum ClaudeInbox {
    /// 发给终端会话的话前面那句说明（会话历史里去掉它，见 `ClaudeHistory`）
    static let userNote = "（这句是用户本人在 CuePad 里发给你的，不是别的会话：直接在本会话里回答，不需要回传。）\n"

    @concurrent static func post(_ lines: Data, to path: String) async throws {
        // 连不上：会话已经退出（socket 删了或没人听）
        guard let fd = try? UnixSocket.connect(path) else { throw PiBridgeError.sessionEnded }
        defer { close(fd) }
        guard writeAll(fd, lines) else { throw PiBridgeError.sessionEnded }
        shutdown(fd, SHUT_WR)
    }
}
#endif
