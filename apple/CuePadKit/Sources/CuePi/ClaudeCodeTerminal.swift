#if os(macOS)
import CueStore
import CueText
import Darwin
import Foundation

/// 在飞的工作只认 `Stop` 带的后台任务清单（`background_tasks`：后台子代理与后台命令，做完了还没交回的也在）：后台任务做完时 Claude Code 自己开一轮交回结果（`UserPromptSubmit` 的正文是 `<task-notification>`），
/// 所以清单只在一轮结束时换，其间等子代理照旧，直到交回结果的那一轮做完。`SubagentStart`/`SubagentStop` 只改名册：
/// 被停下的子代理没有 `SubagentStop`，下一个 `Stop` 的清单里没有它就记成被停下；主会话歇着时停掉的连下一个 `Stop` 也没有，见 `agentsStopped`。
/// 结束是给进程发 SIGINT（与在终端里按 Ctrl-C 退出同一条路：跑 `SessionEnd` 钩子、恢复终端）。
/// 收件箱送到的话 Claude Code 一律当作“另一个会话发来的”（包上同伴消息的说明；行里没有能改这一点的字段，实测 2.1.299），
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
    /// 会话登记文件（`<配置目录>/sessions/<pid>.json`）：它写下 `status` 之后收件箱才收话（`waitUntilReady`）
    private let registry: URL
    private let timing: Timing
    private var ready = false
    /// 在等起好的投送（`waitUntilReady`）各盯着一份登记文件；会话下桥（`close`）时停掉它们，等待随即以会话结束收场
    private var readyWaits: [UUID: FileFollower] = [:]
    private var closed = false
    var facts = SessionFacts()
    /// 刚交上来、还没见它跑起来的这句（之后主会话还没有别的钩子）：挡下的那一行按原话认它（`recorded`）
    var unconfirmedPrompt: String?
    /// 先于这句的钩子读到的挡下那一行的正文（钩子并行跑，Claude Code 不等 CuePad 的钩子就写下它）：只认紧接着的那个 `UserPromptSubmit`
    var refusedAhead: String?
    /// 要你回答的（同一时刻可能有好几个：子代理并行时各自要确认），按到达先后；会话的 `question` 是第一个
    private var pending: [Pending] = []

    private struct Pending {
        var question: PiQuestion
        var kind: Kind
        /// 挂着的钩子；交给终端了（放行了）为 nil，这时只显示
        var call: AgentHookCall?
        /// 主会话为 nil，子代理是它的 `agent_id`
        var agent: String?
        var hold: UUID?

        enum Kind {
            case permission(ClaudePermission)
            case ask(ClaudePermission)
            case elicitation(field: String, type: String, values: [String]?)
        }
    }

    /// - Parameter runningSince: 接上时已在跑（在忙或在等你）这一轮的开始（取法见 `SessionFacts.startTurn(at:)`）
    init(
        id: PiSession.ID, pid: Int32, bridge: PiBridge, gate: PresenceGate, inbox: String?, registry: URL, timing: Timing,
        runningSince: Date?, waiting: Bool
    ) {
        self.id = id
        self.pid = pid
        self.registry = registry
        self.timing = timing
        self.bridge = bridge
        self.gate = gate
        self.inbox = inbox
        if let runningSince { facts.startTurn(at: runningSince) }
        if waiting { facts.questions = [PiQuestion(promptID: nil, kind: .unknown("terminal"), text: String(localized: "在终端里等你"))] }
    }

    func publish(_ session: inout PiSession) { facts.publish(to: &session) }

    func handle(_ event: String, _ input: JSONValue, call: AgentHookCall) {
        let agent = input["agent_id"]?.string
        let now = Date.now
        // 在等的之后同一个代理又有了动静：终端里已经答了（Claude Code 不收回挡着的钩子），不再等
        if event != "PermissionRequest" { settlePending(agent: agent, when: event) }
        bridge?.update(id) { session in
            if let level = input["effort"]?["level"]?.string { session.thinking = Open(rawValue: level) }
            if let title = input["session_title"]?.string, !title.isEmpty { session.name = title }
            // CuePad 经收件箱发的那句带着说明，与会话历史一样去掉
            if session.firstMessage == nil, event == "UserPromptSubmit", let prompt = input["prompt"]?.string.map(ClaudeHistory.withoutPeerWrapper), !prompt.isEmpty {
                session.firstMessage = String(prompt.prefix(PiSessionName.firstMessageLimit))
            }
            // 模型随 SessionStart 来：会话可能已由启动时的列表扫描先补上了（`discover`），钩子晚到也要取
            if let model = input["model"]?.string { session.model = ClaudeCode.model(model) }
            if event == "PostModelSwitch", let model = input["to_model"]?.string { session.model = ClaudeCode.model(model) }
        }
        let tool = input["tool_name"]?.string ?? "?"
        // 主会话又有了别的钩子：这句跑起来了，挡下的那一行不会再来；先读到的那一行也不是之后这句的
        let refused = refusedAhead
        if agent == nil { (unconfirmedPrompt, refusedAhead) = (nil, nil) }
        switch event {
        case "UserPromptSubmit":
            let prompt = input["prompt"]?.string ?? ""
            if let refused, Self.refuses(refused, prompt) { break }  // 挡下的那一行先读到了：这一轮没开成
            facts.startTurn(at: now)  // 钩子挡着这一句：收到它一定早于这一轮的回答
            unconfirmedPrompt = prompt
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
            break
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

    /// 没带清单的（`StopFailure` 文档里没有这一项）不动。
    private func inFlight(_ tasks: JSONValue?, at now: Date) {
        guard let tasks = tasks?.array else { return }
        facts.inFlight = Set(tasks.compactMap { $0["id"]?.string })
        for (agent, state) in facts.subagents where state.phase == .known(.running) && !facts.inFlight.contains(agent) {
            facts.settleSubagent(agent, .interrupted, summary: nil, at: now)
        }
    }

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

    private func handBack(_ promptID: String) {
        guard let index = pending.firstIndex(where: { $0.question.promptID == promptID }) else { return }
        pending[index].call?.finish()
        pending[index].call = nil
        pending[index].hold = nil
        pending[index].question.promptID = nil
        show(at: .now)
    }

    private func watch(_ call: AgentHookCall?, promptID: String) {
        call?.onClose = { [weak self] in self?.withdraw(promptID) }
    }

    /// 会话下桥（进程退出、`SessionEnd`、出了范围）时运行时调用：挂着的钩子放行，在等起好的投送结束（话没写进收件箱）。
    func close() {
        for item in pending {
            item.call?.finish()
            gate.drop(item.hold)
        }
        pending = []
        closed = true
        for follower in readyWaits.values { follower.stop() }
        readyWaits = [:]
    }

    func show(at now: Date) {
        facts.questions = pending.map(\.question)
        bridge?.update(id) { facts.publish(to: &$0, at: now) }
    }

    func settlePending(agent: String?, when event: String) {
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

    /// 只在歇着时送到（在跑时桥先拒收，见 `AgentCapabilities.speakBlocked`）：`next` 让它马上开这一轮。
    func send(_ message: PiMessage, in _: PiSession.ID) async throws {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PiBridgeError.rejected("empty") }
        var line: [String: JSONValue] = [
            "type": "user", "message": ["role": "user", "content": .string(ClaudeInbox.userNote + message.text)], "priority": "next",
        ]
        if let delivery = message.deliveryID { line["uuid"] = .string(delivery) }
        try await post(.object(line))
    }

    func configure(_ config: PiConfig, in _: PiSession.ID) async throws {
        guard config.fast == nil else { throw PiBridgeError.unsupported }
        let name = config.name
        guard let name else { throw PiBridgeError.unsupported }
        try await post(["type": "control", "action": "rename", "name": .string(name)])
        bridge?.update(id) { $0.name = name }
    }

    func answer(_ answer: PiAnswerValue, to promptID: String, in _: PiSession.ID) async throws {
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

    private static func value(_ answer: PiAnswerValue, _ type: String, _ values: [String]?) throws -> JSONValue {
        switch (answer, type) {
        case (.confirmed(let yes), "boolean"): return .bool(yes)
        case (.option(let label), "string") where values?.contains(label) == true: return .string(label)
        case (.text(let text), "string") where values?.isEmpty != false: return .string(text)
        default: throw PiBridgeError.rejected("bad_answer")
        }
    }

    /// 登记文件里的 `status` 随它自己的轮次变，钩子不通（没装、CuePad 之后才起来）时桥上的状态是旧的。只认 `busy`（在跑一轮或等后台任务）：
    /// `waiting` 也可能是收件箱的话被挂起、在等你批准（2.1.318 源码：对话框一律记成 `waiting`，看不出是哪种），算它在跑就会一直等下去。
    func takingTurn(_: PiSession.ID) -> Bool? {
        (try? Data(contentsOf: registry)).flatMap(JSONValue.parse)?["status"]?.string.map { $0 == "busy" }
    }

    func end(_: PiSession.ID) async throws {
        guard kill(pid, SIGINT) == 0 else { throw PiBridgeError.sessionEnded }
    }

    private func post(_ line: JSONValue) async throws {
        guard let inbox else { throw PiBridgeError.unsupported }
        if !ready {
            try await waitUntilReady()
            ready = true
        }
        var lines = Data()
        if let inboxToken { lines += (["type": "auth", "token": .string(inboxToken)] as JSONValue).data + [0x0A] }
        lines += line.data + [0x0A]
        try await ClaudeInbox.post(lines, to: inbox)
    }

    /// 会话一起来（`SessionStart` 钩子）就上桥，这时收件箱已在听，但登记文件里还没有 `status`（起好时写 `idle`）：这之前送到的话
    /// 即使带着令牌也按来路不明挂起，跳过权限确认的会话不交给模型、等你在终端里批准（2.1.318 实测：上桥就发，12 次挂起 7 次；
    /// 等到 `status` 再发，24 次都送到）。有收件箱的各版（2.1.224 起；实跑 224、250、280、300、317、318）起好时都写 `status`。
    /// 盯文件变化等（`FileFollower`），不轮询。进程存亡只认运行时的退出监视：它让会话下桥（`close`），这里随即报会话已结束——
    /// 话确定没写进收件箱，所以是 `unknownSession`（确定没发出），不是表示"写了之后断开、结果未知"的 `sessionEnded`。
    private func waitUntilReady() async throws {
        guard !closed else { throw PiBridgeError.unknownSession(id) }
        let follower = FileFollower()
        let key = UUID()
        readyWaits[key] = follower
        defer {
            readyWaits[key] = nil
            follower.stop()
        }
        follower.follow(only: [registry.realPath.path])
        do {
            try await withDeadline(AgentTimeouts.terminalReady, timing: timing, orThrow: PiBridgeError.rejected("not_ready")) { [registry] in
                for await _ in follower.paths {
                    if (try? Data(contentsOf: registry)).flatMap(JSONValue.parse)?["status"]?.string != nil { return }
                }
                throw CancellationError()
            }
        } catch is CancellationError where closed {
            throw PiBridgeError.unknownSession(id)
        }
    }
}
#endif
