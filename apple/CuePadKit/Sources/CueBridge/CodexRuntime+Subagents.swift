#if os(macOS)
import CueStore
import CueText
import Foundation

extension CodexRuntime {
    func notification(_ method: String, _ params: JSONValue, in session: Tracked) {
        // 子代理的线程没有 `thread/started`：报出来的顶层线程不是子代理（Codex 起的临时线程等），之后它的推送不必去问
        if method == "thread/started", let thread = params["thread"], let id = thread["id"]?.string, thread["parentThreadId"]?.string == nil {
            session.threads[id] = session.threads[id] ?? .foreign
        }
        guard let threadID = params["threadId"]?.string else { return }
        if let turn = session.naming[threadID] { return turn.receive(method, params) }
        guard threadID == session.threadID else { return child(method, params, thread: threadID, in: session) }
        switch method {
        case "thread/settings/updated":
            if let settings = params["threadSettings"] {
                bridge.update(session.id) { s in
                    s.fast = settings["serviceTier"]?.string == "priority"
                    if let model = settings["model"]?.string { s.model = self.option(model) }
                    s.thinking = settings["effort"]?.string.map(CodexModel.thinking)
                }
            }
            return
        case "thread/name/updated":
            bridge.update(session.id) { $0.name = params["threadName"]?.string }
            return
        case "item/started", "item/completed":
            guard let item = params["item"] else { return }
            self.item(item, started: method == "item/started", in: session)
        case "serverRequest/resolved":
            guard session.reply?.request == params["requestId"] else { return }
            session.reply = nil
            session.turns.facts.questions = []
        case "thread/closed":
            return detach(session.id)
        default:
            return
        }
        publish(session)
    }

    /// 线程里的一项：你说的话收起不挡着这一轮的提问，Codex 登记了的这种提问、压缩、派出的子代理（任务名是 `agentPath` 的末段，同认出后名册里的名字 `owner`；
    /// 已认出的同名线程不再等：早到的推送，或前几轮派过同名的）。
    private func item(_ item: JSONValue, started: Bool, in session: Tracked) {
        switch (item["type"]?.string, started) {
        case ("userMessage", true):
            let text = (item["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
            guard !text.isEmpty else { return }
            session.turns.facts.standingQuestion = nil
            bridge.update(session.id) { s in
                if s.firstMessage == nil { s.firstMessage = text }
            }
        case ("agentMessage", false) where item["delivery"]?.string == "async":
            session.turns.facts.standingQuestion = Self.asyncQuestion(item["questions"])
        case ("contextCompaction", _):
            session.turns.facts.compacting = started
        case ("subAgentActivity", true) where item["kind"]?.string == "started":
            guard let name = item["agentPath"]?.string?.split(separator: "/").last.map(String.init) else { return }
            let known = session.threads.values.contains { if case .child(name, _) = $0 { true } else { false } }
            if !known { session.spawned.insert(name) }
        default:
            break
        }
    }

    /// 托管会话的一轮（它的驱动报的）接到桥上。以一句话开新一轮时（`deliver`），这一轮开始就是那句开出的，之后的结束照常歇下。
    func event(_ event: TurnEvent, in session: Tracked) {
        guard tracked[session.id] === session else { return }
        if case .exited = event { return detach(session.id) }
        switch event {
        case .turnStarted:
            startTurn(session, at: session.sentAt ?? .now)
        case .turnFinished:
            endTurn(session)
        case .failed, .tool, .toolDone:
            session.turns.apply(event)
        case .speaking, .context:
            return bridge.show(event, in: session.id)
        case .exited, .received:
            return
        }
        publish(session)
    }

    /// 同一进程上还有认不出主人的线程（推送先到、还在问或第一次没读到），或这一轮派出的子代理还没露面（推送还没到，`spawned`）时先不歇下：
    /// 不等就会先报歇下、认出后再进“等子代理”。由这次结束触发一起再问一遍、等派出的认出，至多 `AgentTimeouts.settleAsk`：认出的进名册，
    /// 仍读不到、没及时回的等它下一条推送再问（`resolve`）；问完歇下。
    /// 换轮中（`HostedTurns.handingOver`）被停下的那一轮不等，直接交给下一轮。
    func endTurn(_ session: Tracked) {
        session.reply = nil
        session.sentAt = nil
        guard !session.turns.handingOver else { session.turns.apply(.turnFinished); return }
        guard session.ending == nil else { return }
        let unknown = session.threads.compactMap { thread, owner in owner.pending == nil ? nil : thread }
        guard !unknown.isEmpty || !session.spawned.isEmpty else { session.turns.apply(.turnFinished); return }
        let recognized = Occurrences(timeout: nil, timing: timing, timeoutError: CancellationError())
        session.recognized = recognized
        session.ending = Task {
            try? await withDeadline(AgentTimeouts.settleAsk, timing: timing, orThrow: CancellationError()) { @MainActor in
                await withTaskGroup { group in
                    for thread in unknown { group.addTask { await self.resolve(thread, in: session) } }
                }
                // 读不到的线程认不出名字：派出的算在其中，照上面的规则先歇下；还在问的等它问完
                while session.spawned.count > session.threads.values.count(where: { if case .unreadable = $0 { true } else { false } }) {
                    try await recognized.next()
                }
            }
            guard !Task.isCancelled, tracked[session.id] === session else { return }
            session.ending = nil
            session.turns.apply(.turnFinished)
            if !session.unread.isEmpty { wake(session) }
            publish(session)
        }
    }

    /// `start` 是这一轮开始的时刻，早于它可能的结束。开始一轮只经这里。
    func startTurn(_ session: Tracked, at start: Date) {
        session.sentAt = nil
        session.ending?.cancel()
        session.ending = nil
        session.spawned = []
        session.turns.apply(.turnStarted, at: start)
        session.turns.facts.inFlight.subtract(session.unread.keys)
        session.unread = [:]
    }

    private static let childMethods: Set = ["turn/started", "turn/completed", "thread/status/changed", "item/started", "item/completed"]

    func child(_ method: String, _ params: JSONValue, thread: String, in session: Tracked) {
        guard Self.childMethods.contains(method) else { return }
        switch session.threads[thread] {
        case .child(let name, let role):
            childEvent(method, params, child: thread, name: name, role: role, in: session)
        case .foreign:
            return
        case .asking(let queued):
            session.threads[thread] = .asking(queued + [(method, params)])
        case .unreadable(let queued):
            session.threads[thread] = .asking(queued + [(method, params)])
            Task { await resolve(thread, in: session) }
        case nil:
            session.threads[thread] = .asking([(method, params)])
            Task { await resolve(thread, in: session) }
        }
    }

    /// 读不到、被取消（新一轮开始、再问到点）都留作暂时读不到，等它下一条推送再问；连接没了（进程退出）就不再记它。
    /// 读的时候到的推送也算“下一条”：刚起的子线程会话文件还是空的（读到 `rollout … is empty`），子代理答得快时它的推送在这次读回来之前就发完了，
    /// 之后再没有推送（`turn/completed` 先于会话文件写盘发出，0.167 的 `tasks/mod.rs`），不接着问它就一直认不出。
    private func resolve(_ thread: String, in session: Tracked) async {
        if case .unreadable(let queued) = session.threads[thread] { session.threads[thread] = .asking(queued) }
        while true {
            guard tracked[session.id] === session, let rpc = session.driver.rpc else {
                session.threads[thread] = nil
                return
            }
            let seen = session.threads[thread]?.pending?.count ?? 0
            if let info = try? await rpc.call("thread/read", ["threadId": .string(thread)])["thread"] { return await register(info, on: rpc, in: session) }
            guard !Task.isCancelled, let now = session.threads[thread]?.pending?.count, now > seen else { return unresolved(thread, in: session) }
        }
    }

    private func unresolved(_ thread: String, in session: Tracked) {
        if case .asking(let queued) = session.threads[thread] { session.threads[thread] = .unreadable(queued) }
        session.recognized?.happened()
    }

    private func register(_ thread: JSONValue, on rpc: CodexRPC, in session: Tracked) async {
        guard let child = thread["id"]?.string else { return }
        let owner: Owner, last: JSONValue?
        do {
            owner = try await self.owner(of: thread, on: rpc, in: session)
            if case .child = owner { last = try await Self.lastTurn(child, on: rpc) } else { last = nil }
        } catch {
            return unresolved(child, in: session)
        }
        let running = last?["status"]?.string == "inProgress"
        // 同一线程同时在问的另一次（推送触发的与歇下前的再问）先没读到时，这次读到的照样算
        guard let queued = session.threads[child]?.pending else { return }
        session.threads[child] = owner
        if case .child(let name, _) = owner, session.spawned.remove(name) != nil { session.recognized?.happened() }
        if case .child(let name, let role) = owner, !session.turns.facts.subagents.contains(where: { $0.id == child }), running || last != nil {
            let date = { (field: String) in thread[field]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now }
            session.turns.facts.startSubagent(child, name: name, role: role, at: date("createdAt"))
            if running {
                session.turns.facts.updateSubagent(child, at: date("updatedAt")) { $0.progressAt = date("updatedAt") }
                session.turns.facts.inFlight.insert(child)
            } else {
                session.turns.facts.settleSubagent(child, Self.phase(of: last), summary: nil, at: date("updatedAt"))
            }
            publish(session)
        }
        for (method, params) in queued { self.child(method, params, thread: child, in: session) }
    }

    /// 名字是派它时给的任务名（v2 的 `agent_path` 末段），没有就用 Codex 起的昵称。沿父线程到顶也不是这个会话才是别人的；中途读不到抛出（认不清）。
    private func owner(of thread: JSONValue, on rpc: CodexRPC, in session: Tracked) async throws -> Owner {
        let spawn = thread["source"]?["subAgent"]?["thread_spawn"]
        let role = thread["agentRole"]?.string ?? spawn?["agent_role"]?.string ?? "default"
        let path = spawn?["agent_path"]?.string.flatMap { $0.split(separator: "/").last.map(String.init) }
        let name = path ?? thread["agentNickname"]?.string ?? role
        var current = thread
        while let parent = current["parentThreadId"]?.string {
            if parent == session.threadID { return .child(name: name, role: role) }
            if case .child = session.threads[parent] { return .child(name: name, role: role) }
            guard let up = try await rpc.call("thread/read", ["threadId": .string(parent)])["thread"] else { break }
            current = up
        }
        return .foreign
    }

    private func childEvent(_ method: String, _ params: JSONValue, child: String, name: String, role: String, in session: Tracked) {
        let now = Date.now
        switch method {
        case "turn/started":
            // 再跑一轮（v2 的 followup_task、v1 的 send_input）也是在跑
            session.turns.facts.runSubagent(child, name: name, role: role, at: now)
            session.unread[child] = nil
            session.turns.facts.inFlight.insert(child)
        case "turn/completed":
            let turn = params["turn"]
            let phase = Self.phase(of: turn)
            settle(child, phase, summary: phase == .failed ? CodexModel.failure(of: turn) : session.lastWords[child], in: session)
        case "thread/status/changed":
            switch params["status"]?["type"]?.string {
            case "systemError": settle(child, .failed, summary: session.lastWords[child], in: session)
            case "notLoaded": settle(child, .interrupted, summary: nil, in: session)
            default: return
            }
        default:
            let item = params["item"]
            if method == "item/completed", item?["type"]?.string == "agentMessage", let text = item?["text"]?.string {
                session.lastWords[child] = text
            }
            let tool = method == "item/started" ? item.flatMap(CodexDriver.tool) : nil
            session.turns.facts.updateSubagent(child, at: now) { agent in
                if let tool { agent.action = ToolDetail.line(tool.name, tool.arguments) }
                agent.progressAt = now
            }
        }
        publish(session)
    }

    /// 线程最近的一轮。认出子代理时在不在跑看它（`inProgress`），不看 `thread/read` 给的线程状态：子代理睡着等（`clock.sleep`）时
    /// 读到的是 idle，它这一轮还没结束（实测）。
    static func lastTurn(_ thread: String, on rpc: CodexRPC) async throws -> JSONValue? {
        try await rpc.call("thread/turns/list", ["threadId": .string(thread), "limit": 1])["data"]?.array?.first
    }

    private static func phase(of turn: JSONValue?) -> SubagentPhase {
        switch turn?["status"]?.string {
        case "completed": .done
        case "failed": .failed
        default: .interrupted
        }
    }

    private func settle(_ child: String, _ phase: SubagentPhase, summary: String?, in session: Tracked) {
        guard session.turns.facts.inFlight.contains(child), session.unread[child] == nil else { return }
        session.turns.facts.settleSubagent(child, phase, summary: summary, at: .now)
        session.lastWords[child] = nil
        if session.turns.facts.running, session.ending == nil {
            session.turns.facts.inFlight.remove(child)
        } else {
            session.unread[child] = phase != .interrupted
            wake(session)
        }
    }

    /// 空输入的一轮先把子代理的结果取进来再请求模型；带文字的一轮先请求模型，v2 的结果要到之后才取出，模型会答“还没收到”。
    /// 同 Codex 的 `wake_on_agent_messages`（openai/codex#54961，未发布、默认关、不管 v1，发布并默认开启后改用它），边界也照它：
    /// 父线程上一轮被停下、在 Plan 模式、这一批没有交回结果（都被停下）的不补，直接歇下。
    private func wake(_ session: Tracked) {
        let batch = session.turns.facts.inFlight
        guard !session.turns.facts.running, batch == Set(session.unread.keys) else { return }
        let delivered = session.unread.values.contains(true)
        let file = bridge.session(id: session.id)?.sessionFile
        Task {
            var last: CodexHistory.LastTurn?
            if delivered, let file { last = await CodexHistory.lastTurn(in: file) }
            guard tracked[session.id] === session, !session.turns.facts.running, session.turns.facts.inFlight == batch else { return }
            if delivered, last?.plan != true, last?.interrupted != true, await session.turns.open({ try await turnStart(session, []) }) { return }
            // 不补，或没开成（已带着原因歇下）：这一批不再等。补开路上开跑的不在这一批里，照等；其间已做完的，它那次补开见批次变了不开，由这里补
            session.unread = session.unread.filter { !batch.contains($0.key) }
            session.turns.facts.inFlight.subtract(batch)
            if !session.unread.isEmpty { wake(session) }
            publish(session)
        }
    }
}
#endif
