#if os(macOS)
import CueStore
import CueText
import Foundation

extension CodexRuntime {
    func notification(_ method: String, _ params: JSONValue, from pid: Int32) {
        // 子代理的线程没有 `thread/started`：报出来的顶层线程不是子代理（Codex 起的临时线程等），之后它的推送不必去问
        if method == "thread/started", let thread = params["thread"], let id = thread["id"]?.string, thread["parentThreadId"]?.string == nil {
            threads["\(id).\(pid)"] = threads["\(id).\(pid)"] ?? .foreign
        }
        guard let threadID = params["threadId"]?.string else { return }
        if let turn = naming["\(threadID).\(pid)"] { return turn.receive(method, params) }
        guard let session = tracked["\(threadID).\(pid)"] else { return child(method, params, thread: threadID, pid: pid) }
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
            session.facts.questions = []
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
            session.facts.standingQuestion = nil
            bridge.update(session.id) { s in
                if s.firstMessage == nil { s.firstMessage = String(text.prefix(SessionName.firstMessageLimit)) }
            }
        case ("agentMessage", false) where item["delivery"]?.string == "async":
            session.facts.standingQuestion = Self.asyncQuestion(item["questions"])
        case ("contextCompaction", _):
            session.facts.compacting = started
        case ("subAgentActivity", true) where item["kind"]?.string == "started":
            guard let name = item["agentPath"]?.string?.split(separator: "/").last.map(String.init) else { return }
            let known = threads.values.contains { if case .session(session.id, name, _) = $0 { true } else { false } }
            if !known { session.spawned.insert(name) }
        default:
            break
        }
    }

    /// 托管会话的一轮（它的驱动报的）接到桥上。以一句话开新一轮时（`deliver`），这一轮开始就是那句开出的，之后的结束照常歇下。
    func event(_ event: TurnEvent, from pid: Int32) {
        if case .exited = event { return processGone(pid) }
        guard let thread = hosted[pid]?.thread, let session = tracked["\(thread).\(pid)"] else { return }
        switch event {
        case .turnStarted:
            session.restarting = nil
            startTurn(session, at: session.sentAt ?? .now)
        case .failed(let text):
            session.lastError = text
            return
        case .turnFinished:
            endTurn(session, failure: session.lastError)
        case .tool(_, let name, let arguments):
            session.facts.work(.tool, detail: ToolDetail.line(name, JSONValue.parse(Data(arguments.utf8))))
        case .toolDone:
            session.facts.work(.thinking)
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
    /// 这一轮出错的原因只记在 `facts.failure`，只有新一轮开始（`startTurn`）清空。
    func endTurn(_ session: Tracked, failure: String?) {
        session.reply = nil
        session.sentAt = nil
        guard session.restarting == nil else { session.restarting = .stopped; return }
        if let failure { session.facts.failure = failure }
        guard session.ending == nil else { return }
        let unknown = unresolvedThreads(on: session.pid)
        guard !unknown.isEmpty || !session.spawned.isEmpty else { return session.facts.endTurn(failure: session.facts.failure) }
        let pid = session.pid
        let recognized = Occurrences(timeout: nil, timing: timing, timeoutError: CancellationError())
        session.recognized = recognized
        session.ending = Task {
            try? await withDeadline(AgentTimeouts.settleAsk, timing: timing, orThrow: CancellationError()) { @MainActor in
                await withTaskGroup { group in
                    for thread in unknown { group.addTask { await self.resolve(thread, pid: pid) } }
                }
                // 读不到的线程认不出名字：派出的算在其中，照上面的规则先歇下；还在问的等它问完
                while session.spawned.count > self.unreadableThreads(on: pid) { try await recognized.next() }
            }
            guard !Task.isCancelled, tracked[session.id] === session else { return }
            session.ending = nil
            guard session.restarting == nil else { session.restarting = .stopped; return }
            session.facts.endTurn(failure: session.facts.failure)
            if !session.unread.isEmpty { wake(session) }
            publish(session)
        }
    }

    private func unreadableThreads(on pid: Int32) -> Int {
        threads.count { key, owner in
            if case .unreadable = owner { key.hasSuffix(".\(pid)") } else { false }
        }
    }

    private func unresolvedThreads(on pid: Int32) -> [String] {
        let suffix = ".\(pid)"
        return threads.compactMap { key, owner in
            switch owner {
            case .asking, .unreadable: key.hasSuffix(suffix) ? String(key.dropLast(suffix.count)) : nil
            case .session, .foreign: nil
            }
        }
    }

    /// `start` 是这一轮开始的时刻，早于它可能的结束。开始一轮只经这里。
    func startTurn(_ session: Tracked, at start: Date) {
        session.sentAt = nil
        session.ending?.cancel()
        session.ending = nil
        session.spawned = []
        session.lastError = nil
        session.facts.startTurn(at: start)
        session.facts.inFlight.subtract(session.unread.keys)
        session.unread = [:]
    }

    private static let childMethods: Set = ["turn/started", "turn/completed", "thread/status/changed", "item/started", "item/completed"]

    func child(_ method: String, _ params: JSONValue, thread: String, pid: Int32) {
        guard Self.childMethods.contains(method) else { return }
        let key = "\(thread).\(pid)"
        switch threads[key] {
        case .session(let id, let name, let role):
            guard let session = tracked[id] else { return }
            childEvent(method, params, child: thread, name: name, role: role, in: session)
        case .foreign:
            return
        case .asking(let queued):
            threads[key] = .asking(queued + [(method, params)])
        case .unreadable(let queued):
            threads[key] = .asking(queued + [(method, params)])
            Task { await resolve(thread, pid: pid) }
        case nil:
            threads[key] = .asking([(method, params)])
            Task { await resolve(thread, pid: pid) }
        }
    }

    /// 读不到、被取消（新一轮开始、再问到点）都留作暂时读不到，等它下一条推送再问；连接没了（进程退出）就不再记它。
    /// 读的时候到的推送也算“下一条”：刚起的子线程会话文件还是空的（读到 `rollout … is empty`），子代理答得快时它的推送在这次读回来之前就发完了，
    /// 之后再没有推送（`turn/completed` 先于会话文件写盘发出，0.167 的 `tasks/mod.rs`），不接着问它就一直认不出。
    private func resolve(_ thread: String, pid: Int32) async {
        let key = "\(thread).\(pid)"
        if case .unreadable(let queued) = threads[key] { threads[key] = .asking(queued) }
        while true {
            guard let rpc = hosted[pid]?.rpc else {
                threads[key] = nil
                return
            }
            let seen = threads[key]?.pending?.count ?? 0
            if let info = try? await rpc.call("thread/read", ["threadId": .string(thread)])["thread"] { return await register(info, on: rpc) }
            guard !Task.isCancelled, let now = threads[key]?.pending?.count, now > seen else { return unresolved(key, pid: pid) }
        }
    }

    private func unresolved(_ key: String, pid: Int32) {
        if case .asking(let queued) = threads[key] { threads[key] = .unreadable(queued) }
        for session in tracked.values where session.pid == pid { session.recognized?.happened() }
    }

    func register(_ thread: JSONValue, on rpc: CodexRPC) async {
        guard let child = thread["id"]?.string else { return }
        let key = "\(child).\(rpc.pid)"
        let owner: Owner, last: JSONValue?
        do {
            owner = try await self.owner(of: thread, on: rpc)
            if case .session = owner { last = try await Self.lastTurn(child, on: rpc) } else { last = nil }
        } catch {
            return unresolved(key, pid: rpc.pid)
        }
        let running = last?["status"]?.string == "inProgress"
        // 同一线程同时在问的另一次（推送触发的与歇下前的再问）先没读到时，这次读到的照样算
        guard let queued = threads[key]?.pending else { return }
        threads[key] = owner
        if case .session(let id, let name, _) = owner, let session = tracked[id], session.spawned.remove(name) != nil { session.recognized?.happened() }
        if case .session(let id, let name, let role) = owner, let session = tracked[id],
           !session.facts.subagents.contains(where: { $0.id == child }), running || last != nil {
            let date = { (field: String) in thread[field]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now }
            session.facts.startSubagent(child, name: name, role: role, at: date("createdAt"))
            if running {
                session.facts.updateSubagent(child, at: date("updatedAt")) { $0.progressAt = date("updatedAt") }
                session.facts.inFlight.insert(child)
            } else {
                session.facts.settleSubagent(child, Self.phase(of: last), summary: nil, at: date("updatedAt"))
            }
            publish(session)
        }
        for (method, params) in queued { self.child(method, params, thread: child, pid: rpc.pid) }
    }

    /// 名字是派它时给的任务名（v2 的 `agent_path` 末段），没有就用 Codex 起的昵称。沿父线程到顶也不是跟踪着的会话才是别人的；中途读不到抛出（认不清）。
    private func owner(of thread: JSONValue, on rpc: CodexRPC) async throws -> Owner {
        let spawn = thread["source"]?["subAgent"]?["thread_spawn"]
        let role = thread["agentRole"]?.string ?? spawn?["agent_role"]?.string ?? "default"
        let path = spawn?["agent_path"]?.string.flatMap { $0.split(separator: "/").last.map(String.init) }
        let name = path ?? thread["agentNickname"]?.string ?? role
        var current = thread
        while let parent = current["parentThreadId"]?.string {
            let key = "\(parent).\(rpc.pid)"
            if let session = tracked[key] { return .session(session.id, name: name, role: role) }
            if case .session(let id, _, _) = threads[key] { return .session(id, name: name, role: role) }
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
            session.facts.runSubagent(child, name: name, role: role, at: now)
            session.unread[child] = nil
            session.facts.inFlight.insert(child)
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
            session.facts.updateSubagent(child, at: now) { agent in
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
        guard session.facts.inFlight.contains(child), session.unread[child] == nil else { return }
        session.facts.settleSubagent(child, phase, summary: summary, at: .now)
        session.lastWords[child] = nil
        if session.facts.running, session.ending == nil {
            session.facts.inFlight.remove(child)
        } else {
            session.unread[child] = phase != .interrupted
            wake(session)
        }
    }

    /// 空输入的一轮先把子代理的结果取进来再请求模型；带文字的一轮先请求模型，v2 的结果要到之后才取出，模型会答“还没收到”。
    /// 同 Codex 的 `wake_on_agent_messages`（openai/codex#54961，未发布、默认关、不管 v1，发布并默认开启后改用它），边界也照它：
    /// 父线程上一轮被停下、在 Plan 模式、这一批没有交回结果（都被停下）的不补，直接歇下。
    private func wake(_ session: Tracked) {
        let batch = session.facts.inFlight
        guard !session.facts.running, batch == Set(session.unread.keys) else { return }
        let delivered = session.unread.values.contains(true)
        let file = bridge.session(id: session.id)?.sessionFile
        Task {
            var last: CodexHistory.LastTurn?
            if delivered, let file { last = await CodexHistory.lastTurn(in: file) }
            guard tracked[session.id] === session, !session.facts.running, session.facts.inFlight == batch else { return }
            guard delivered, last?.plan != true, last?.interrupted != true else {
                session.unread = [:]
                session.facts.inFlight = []
                return publish(session)
            }
            do {
                try await turnStart(session, [])
            } catch {
                // 没开成：这一批不再等，带着原因歇下
                guard tracked[session.id] === session, !session.facts.running else { return }
                session.unread = [:]
                session.facts.inFlight = []
                session.facts.endTurn(failure: error.localizedDescription)
                publish(session)
            }
        }
    }
}
#endif
