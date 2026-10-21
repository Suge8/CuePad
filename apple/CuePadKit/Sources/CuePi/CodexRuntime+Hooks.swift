#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

extension CodexRuntime {
    func hook(_ call: AgentHookCall) {
        guard let input = JSONValue.parse(call.envelope.input), let event = input["hook_event_name"]?.string,
              let threadID = input["session_id"]?.string else { return call.finish() }
        let pid = hostedPID(of: call.envelope, thread: threadID) ?? call.envelope.pid
        let id = "\(threadID).\(pid)"
        if event == "SessionEnd" {
            call.finish()
            return detach(id)
        }
        let agent = input["agent_id"]?.string
        guard tracked[id] != nil || scope.covers(sessionID: threadID) else { return call.finish() }
        let session = tracked[id] ?? adoptFromHook(threadID, pid: pid, input, transcript: agent == nil)
        let tool = input["tool_name"]?.string ?? ""
        let now = Date.now
        switch event {
        case "PermissionRequest":
            // 子代理要的确认也挂在这个会话上问
            return ask(session, call: call, input)
        case _ where agent != nil:
            // 子代理自己线程里的事件（session_id 是同一棵树的根，agent_id 是它自己）：只更新它在做什么
            if event == "PreToolUse", let agent { session.facts.updateSubagent(agent, at: now) { $0.action = ToolDetail.line(tool, input["tool_input"]) } }
        case "UserPromptSubmit":
            session.facts.standingQuestion = nil
            // 钩子里没有时刻：用收到它的时刻
            startTurn(session, at: now)
            bridge.update(id) { s in
                if s.firstMessage == nil, let prompt = input["prompt"]?.string, !prompt.isEmpty {
                    s.firstMessage = String(prompt.prefix(PiSessionName.firstMessageLimit))
                }
            }
            refresh(id)
        case "PreToolUse":
            if tool == "request_user_input", session.reply == nil {
                // 终端会话的 Plan 模式提问只发给终端界面：CuePad 只显示（托管的经 `item/tool/requestUserInput` 来）
                session.facts.questions = [Self.userInput(input["tool_input"] ?? .object([:]), promptID: nil)]
            } else {
                session.facts.work(.tool, detail: ToolDetail.line(tool, input["tool_input"]))
            }
        case "PostToolUse" where tool == Self.asyncQuestionTool:
            session.facts.standingQuestion = Self.asyncQuestion(input["tool_input"])
            session.facts.work(.thinking)
        case "PostToolUse":
            if session.reply == nil { session.facts.questions = [] }
            session.facts.work(.thinking)
        case "PreCompact":
            session.facts.compacting = true
        case "PostCompact":
            session.facts.compacting = false
        case "Stop", "Interrupt":
            endTurn(session)
            refresh(id)
        default:
            break
        }
        call.finish()
        publish(session)
    }

    /// 钩子来自哪个托管进程：环境里带着它的标记，且线程是它承载的（或它还没有上桥的线程：刚开、刚接着）。
    /// Agent 在托管会话里再起的 codex 也继承标记，但线程不同，算终端会话。
    private func hostedPID(of envelope: AgentHookEnvelope, thread: String) -> Int32? {
        guard let mark = envelope.environment[HostMark.variable], let pid = marks[mark] else { return nil }
        return tracked["\(thread).\(pid)"] != nil || !tracked.values.contains(where: { $0.pid == pid }) ? pid : nil
    }

    /// 钩子先于其他途径报出的会话（终端里刚开、或 CuePad 晚启动）：接上桥，名字与模型随后从 Codex 读。
    /// 子代理的钩子（`transcript` 为 false）带的会话文件是子代理自己的，不用。
    private func adoptFromHook(_ threadID: String, pid: Int32, _ input: JSONValue, transcript: Bool) -> Tracked {
        let session = PiSession(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex,
            sessionFile: transcript ? input["transcript_path"]?.string.map { URL(filePath: $0) } : nil,
            pid: pid, cwd: URL(filePath: input["cwd"]?.string ?? "/", directoryHint: .isDirectory), terminal: PiTerminal(),
            state: .settled, stateSince: .now)
        attach(session)
        return tracked[session.id]!
    }

    // MARK: 等你回答

    /// 权限确认：托管的会话总是挂住等 CuePad 作答；终端会话按人在不在（`PresenceGate`）：人在就放行、终端弹框，CuePad 只显示。
    /// 钩子先走了（终端里停下了这一轮）就收起问题。
    private func ask(_ session: Tracked, call: AgentHookCall, _ input: JSONValue) {
        let arguments = input["tool_input"] ?? .object([:])
        let command = arguments["command"]?.string
        let text = PermissionWording.question(
            .codex, command == nil ? "使用 \(input["tool_name"]?.string.map(ToolDetail.name) ?? "工具")" : "运行命令", [command, arguments["description"]?.string])
        release(session)
        let promptID = UUID().uuidString
        var hold: UUID?
        if hosted[session.pid] == nil {
            hold = gate.hold { [weak self, weak session] in
                guard let self, let session, case .hook(let held, _) = session.reply, held === call else { return }
                self.handBack(session)
            }
            guard hold != nil else {
                call.finish()
                session.facts.questions = [PiQuestion(promptID: nil, kind: .confirm, text: text)]
                return publish(session)
            }
        }
        session.reply = .hook(call, hold: hold)
        session.facts.questions = [PiQuestion(promptID: promptID, kind: .confirm, text: text)]
        call.onClose = { [weak self, weak session] in
            guard let self, let session, case .hook(let held, _) = session.reply, held === call else { return }
            self.release(session)
            session.facts.questions = []
            self.publish(session)
        }
        publish(session)
    }

    /// 人回来了：挂住的放行，终端补弹；CuePad 里还显示，只能在终端里答。
    private func handBack(_ session: Tracked) {
        guard case .hook(let call, _) = session.reply else { return }
        session.reply = nil
        call.finish()
        session.facts.questions = session.facts.questions.map { PiQuestion(promptID: nil, kind: $0.kind, text: $0.text, options: $0.options) }
        publish(session)
    }

    /// 放掉在等的（挂住的钩子放行；托管线程的提问不再等），问题由调用方收起。
    func release(_ session: Tracked) {
        if case .hook(let call, let hold) = session.reply {
            call.finish()
            gate.drop(hold)
        }
        session.reply = nil
    }

    /// 托管线程的 Plan 模式提问（`item/tool/requestUserInput`）：只有一个问题时能从 CuePad 答（有选项是单选，否则填文字；保密的不答）。
    func userInput(_ params: JSONValue, id: JSONValue, on rpc: CodexRPC) -> Bool {
        guard let threadID = params["threadId"]?.string, let session = tracked["\(threadID).\(rpc.pid)"] else { return false }
        let questions = params["questions"]?.array ?? []
        let answerable = questions.count == 1 && questions.first?["isSecret"]?.bool != true
        let question = Self.userInput(params, promptID: answerable ? UUID().uuidString : nil)
        release(session)
        if answerable, let first = questions.first?["id"]?.string { session.reply = .request(rpc, id: id, question: first) }
        session.facts.questions = [question]
        publish(session)
        return answerable
    }

    /// Plan 模式的提问（`request_user_input` 的参数，一次可能几个，显示第一个）：有选项是单选（`isOther` 的还能自己填），否则填文字；
    /// 标题与问题换行连接。
    static func userInput(_ arguments: JSONValue, promptID: String?) -> PiQuestion {
        let first = arguments["questions"]?.array?.first ?? .object([:])
        let text = [first["header"]?.string, first["question"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let options = (first["options"]?.array ?? []).compactMap { $0["label"]?.string }
        return PiQuestion(
            promptID: promptID, kind: options.isEmpty ? .text : .select, text: String(text.prefix(500)), options: options,
            allowsOther: first["isOther"]?.bool == true)
    }

    static let asyncQuestionTool = "request_user_input_async"

    /// 不挡着这一轮的提问（`request_user_input_async` 的参数，一次可以几个，标题就是完整的问题）：只有一个时照它的选项单选，
    /// 也能自己填（Codex 的界面总给自由作答）；几个时合成一道文字题，一行一问、选项写在后面。
    static func asyncQuestion(_ arguments: JSONValue?) -> PiQuestion? {
        let questions = (arguments?["questions"]?.array ?? []).compactMap { question -> (title: String, options: [String])? in
            guard let title = question["title"]?.string, !title.isEmpty else { return nil }
            return (title, (question["options"]?.array ?? []).compactMap(\.string))
        }
        guard let first = questions.first else { return nil }
        guard questions.count > 1 else {
            return PiQuestion(
                promptID: UUID().uuidString, kind: first.options.isEmpty ? .text : .select, text: String(first.title.prefix(500)),
                options: first.options, allowsOther: !first.options.isEmpty)
        }
        let text = questions.map { $0.options.isEmpty ? $0.title : "\($0.title)（\($0.options.joined(separator: " / "))）" }.joined(separator: "\n")
        return PiQuestion(promptID: UUID().uuidString, kind: .text, text: String(text.prefix(500)))
    }

    /// 作答：权限确认写回钩子（允许或拒绝，附一句给模型看的原因），托管线程挡着这一轮的提问回给服务端请求，
    /// 不挡着的提问把答案当你的下一句话说给它（与发话同一规则）。
    public func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws {
        guard let session = tracked[id], let question = session.facts.question else { throw PiBridgeError.rejected("no_prompt") }
        guard question.promptID == promptID else { throw PiBridgeError.rejected("stale_prompt") }
        guard let reply = session.reply else {
            let text: String
            switch answer {
            case .option(let option) where question.options.contains(option): text = option
            case .text(let written) where question.acceptsText: text = written
            default: throw PiBridgeError.rejected("bad_answer")
            }
            try await deliver(CodexRPC.input(text: text, images: []), clientID: CodexHistory.clientID(for: nil), to: session)
            session.facts.standingQuestion = nil
            return publish(session)
        }
        switch (reply, answer) {
        case (.hook(let call, let hold), .confirmed(let allowed)):
            let decision: JSONValue = ["behavior": allowed ? "allow" : "deny", "message": .string(allowed ? PermissionWording.allowed : PermissionWording.denied)]
            call.reply(JSONValue.object(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]).data)
            gate.drop(hold)
        case (.request(let rpc, let requestID, let questionID), .option(let text)) where question.options.contains(text),
             (.request(let rpc, let requestID, let questionID), .text(let text)) where question.acceptsText:
            rpc.respond(to: requestID, result: ["answers": [questionID: ["answers": [.string(text)]]]])
        default:
            throw PiBridgeError.rejected("bad_answer")
        }
        session.reply = nil
        session.facts.questions = []
        publish(session)
    }
}
#endif
