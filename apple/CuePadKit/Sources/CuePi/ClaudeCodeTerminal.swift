#if os(macOS)
import CueStore
import Darwin
import Foundation

/// 终端里跑的一个 Claude Code 会话：状态由钩子推出（`ClaudeCodeRuntime` 把这个会话的每次钩子调用交给 `handle`），
/// 说话经它的收件箱 socket，作答经挡着的 `PermissionRequest` 钩子，改名经收件箱的 `rename`，结束是给进程发 SIGINT
/// （与在终端里按 Ctrl-C 退出同一条路：跑 `SessionEnd` 钩子、恢复终端）。
///
/// 做不到的（缺省实现抛 `unsupported`）：图片（收件箱只收文字）、停止这一轮（SIGINT 是退出）、换模型与强度、斜杠命令（收件箱送到的斜杠开头的话
/// 只是文字）。收件箱送到的话 Claude Code 当作"另一个会话发来的"，模型会照做，但不当作你本人的指令。
@MainActor
final class ClaudeTerminalSession: SessionLink {
    let id: PiSession.ID
    let pid: Int32
    private weak var bridge: PiBridge?
    /// 收件箱 socket（钩子环境里的 `CLAUDE_CODE_MESSAGING_SOCKET`，或会话登记文件里的）
    var inbox: String?
    /// 在等的确认（同一时刻可能有好几个：子代理并行时各自要确认），按到达先后；会话的 `question` 是第一个
    private var pending: [Pending] = []
    /// 手动压缩前的状态：压完回到它（压缩不是新的一轮）
    private var beforeCompaction: (state: PiWorkState, detail: String?, since: Date, busySince: Date?)?
    /// 子代理按 `agent_id` 认
    private var subagents: [(id: String, state: PiSubagentState)] = []

    private struct Pending {
        var permission: ClaudePermission
        var call: AgentHookCall
        /// 主会话为 nil，子代理是它的 `agent_id`
        var agent: String?
    }

    init(id: PiSession.ID, pid: Int32, bridge: PiBridge, inbox: String?) {
        self.id = id
        self.pid = pid
        self.bridge = bridge
        self.inbox = inbox
    }

    // MARK: 钩子

    /// 一次钩子调用：更新会话；要等答复的（权限确认）留着，其余当场放行。
    func handle(_ event: String, _ input: ClaudeJSON, call: AgentHookCall) {
        let agent = input["agent_id"]?.string
        let now = Date.now
        // 在等的确认之后，同一个代理又有了动静：终端里已经答了（Claude Code 不收回挡着的钩子），不再等
        if event != "PermissionRequest" { settlePending(agent: agent, when: event) }
        bridge?.update(id) { session in
            if let level = input["effort"]?["level"]?.string { session.thinking = Open(rawValue: level) }
            if let title = input["session_title"]?.string, !title.isEmpty { session.name = title }
        }
        switch event {
        case "UserPromptSubmit":
            update { session in
                if session.firstMessage == nil, let prompt = input["prompt"]?.string, !prompt.isEmpty {
                    session.firstMessage = String(prompt.prefix(PiSessionName.firstMessageLimit))
                }
                session.enter(.thinking, at: now)
            }
        case "PreToolUse":
            let detail = ClaudeCode.toolDetail(input["tool_name"]?.string ?? "?", input["tool_input"])
            if let agent {
                updateSubagent(agent) { $0.action = detail }
            } else {
                update { $0.enter(.tool, detail: detail, at: now) }
            }
        case "PostToolUse", "PostToolUseFailure":
            if agent == nil { update { $0.enter(.thinking, at: now) } }
        case "PermissionRequest":
            let permission = ClaudePermission(tool: input["tool_name"]?.string ?? "?", input: input["tool_input"] ?? .object([:]))
            pending.append(Pending(permission: permission, call: call, agent: agent))
            call.onClose = { [weak self] in self?.withdraw(permission.promptID) }
            showQuestion(at: now)
            return
        case "Stop":
            update { $0.enter(rested, at: now) }
        case "StopFailure":
            let raw = [input["error"]?.string, input["error_details"]?.string, input["last_assistant_message"]?.string]
                .compactMap { $0 }.joined(separator: "\n")
            update { session in
                session.enter(.error, detail: PiErrorSummary(raw).line, at: now)
                session.errorMessage = raw
            }
        case "PreCompact":
            update { session in
                if input["trigger"]?.string == "manual" {
                    self.beforeCompaction = (session.state, session.detail, session.stateSince, session.busySince)
                }
                session.enter(.compacting, at: now)
            }
        case "PostCompact":
            let before = beforeCompaction
            beforeCompaction = nil
            update { session in
                guard let before else { return session.enter(.thinking, at: now) }
                session.state = before.state
                session.detail = before.detail
                session.stateSince = before.since
                session.busySince = before.busySince
            }
        case "SubagentStart":
            guard let agent else { break }
            subagents.append((agent, ClaudeCode.subagent(name: "", role: input["agent_type"]?.string ?? "", at: now)))
            publishSubagents()
        case "SubagentStop":
            // 压缩上下文也会报一个没有开始的子代理，不在名册里
            guard let agent else { break }
            updateSubagent(agent) { ClaudeCode.settle(&$0, .done, summary: input["last_assistant_message"]?.string, at: now) }
            update { session in if session.state == .delegating { session.enter(rested, at: now) } }
        case "PostModelSwitch":
            if let model = input["to_model"]?.string { update { $0.model = ClaudeCode.model(model) } }
        default:
            break
        }
        call.finish()
    }

    /// 进程退出或会话结束：还挂着的钩子放掉（进程走了它们也就没了）。
    func close() {
        for item in pending { item.call.finish() }
        pending = []
    }

    private func update(_ change: (inout PiSession) -> Void) { bridge?.update(id, change) }

    /// 这一轮歇下时：还有在后台跑的子代理就是等子代理，否则空闲
    private var rested: PiWorkState { subagents.contains { $0.state.phase == .known(.running) } ? .delegating : .settled }

    private func showQuestion(at now: Date) {
        update { session in
            if let first = pending.first {
                session.question = first.permission.question
                session.enter(.waitingForUser, detail: first.permission.title, at: now)
            } else if session.state == .waitingForUser {
                session.question = nil
                session.enter(.thinking, at: now)
            }
        }
    }

    /// 终端里先答了：同一个代理之后的任一事件说明它已不在等。
    private func settlePending(agent: String?, when event: String) {
        let stale = pending.filter { $0.agent == agent || event == "Stop" || event == "StopFailure" }
        guard !stale.isEmpty else { return }
        for item in stale { item.call.finish() }
        pending.removeAll { item in stale.contains { $0.permission.promptID == item.permission.promptID } }
        showQuestion(at: .now)
    }

    /// 钩子进程先走了（超时、Claude Code 收回）：问题不再等。
    private func withdraw(_ promptID: String) {
        pending.removeAll { $0.permission.promptID == promptID }
        showQuestion(at: .now)
    }

    private func updateSubagent(_ agent: String, _ change: (inout PiSubagentState) -> Void) {
        guard let index = subagents.firstIndex(where: { $0.id == agent }) else { return }
        change(&subagents[index].state)
        publishSubagents()
    }

    private func publishSubagents() {
        let roster = subagents.map(\.state)
        update { $0.subagents = roster }
    }

    // MARK: SessionLink

    func send(_ message: PiMessage) async throws -> PiDelivery {
        guard message.images.isEmpty else { throw PiBridgeError.unsupported }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PiBridgeError.rejected("empty") }
        guard let session = bridge?.session(id: id) else { throw PiBridgeError.sessionEnded }
        let busy = session.state.isTurnRunning
        let mode = message.whenBusy ?? .followUp
        // 收件箱的 now 等在跑的工具做完、在这一轮里插进去（马上说），later 等这一轮做完（等它做完再说）
        var line: [String: ClaudeJSON] = [
            "type": "user", "message": ["role": "user", "content": .string(message.text)],
            "priority": .string(!busy ? "next" : mode == .steer ? "now" : "later"),
        ]
        if let delivery = message.deliveryID { line["uuid"] = .string(delivery) }
        try await post(.object(line))
        return busy ? .queued(mode) : .immediate
    }

    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws {
        guard model == nil, thinking == nil, let name else { throw PiBridgeError.unsupported }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PiBridgeError.rejected("bad_request") }
        try await post(["type": "control", "action": "rename", "name": .string(trimmed)])
        update { $0.name = trimmed }
    }

    func answer(_ answer: PiAnswerValue, to promptID: String) async throws {
        guard let index = pending.firstIndex(where: { $0.permission.promptID == promptID }) else {
            throw PiBridgeError.rejected(pending.isEmpty ? "no_prompt" : "stale_prompt")
        }
        let item = pending[index]
        let decision = try item.permission.decision(answer, to: promptID)
        let output: ClaudeJSON = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        item.call.reply(output.data + Data([0x0A]))
        pending.remove(at: index)
        showQuestion(at: .now)
    }

    func end() async throws {
        guard kill(pid, SIGINT) == 0 else { throw PiBridgeError.sessionEnded }
    }

    private func post(_ line: ClaudeJSON) async throws {
        guard let inbox else { throw PiBridgeError.unsupported }
        try await ClaudeInbox.post(line.data + Data([0x0A]), to: inbox)
    }
}

/// Claude Code 会话的收件箱（跨会话消息的 Unix socket，2.1.224 起）：连上、写一行、关掉。它不回话；macOS 上不要求先发 auth 行。
enum ClaudeInbox {
    @concurrent static func post(_ line: Data, to path: String) async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw PiBridgeError.sessionEnded }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // 连不上：会话已经退出（socket 删了或没人听）
        guard connected == 0 else { throw PiBridgeError.sessionEnded }
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw PiBridgeError.sessionEnded }
                offset += n
            }
        }
        shutdown(fd, SHUT_WR)
    }
}
#endif
