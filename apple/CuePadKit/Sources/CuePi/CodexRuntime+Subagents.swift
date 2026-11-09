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
        // 托管会话的一轮归它的驱动（`event`），下面两项只管终端会话
        let terminal = hosted[pid] == nil
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
        case "thread/status/changed" where terminal:
            switch params["status"]?["type"]?.string {
            // 钩子漏报的歇下（出错的一轮没有 Stop）；钩子的 Stop 晚到也只是再歇一次。睡着等（`clock.sleep`）时不报 idle（实测）
            case "idle" where session.facts.running:
                endTurn(session)
            case "systemError":
                endTurn(session, failure: session.lastError ?? String(localized: "Codex 出错了"))
                if session.lastError == nil { readFailure(session) }
            default: return
            }
        case "error" where terminal && params["willRetry"]?.bool != true:
            // 出错的原文（常驻服务也广播）；随后的 systemError 用它
            session.lastError = CodexModel.failure(of: params)
            return
        // 以下只有开出这个线程的连接（托管的进程）收得到
        case "serverRequest/resolved":
            guard case .request = session.reply else { return }
            session.reply = nil
            session.facts.questions = []
        case "thread/closed":
            return detach(session.id)
        default:
            return
        }
        publish(session)
    }

    /// 托管会话的一轮（它的驱动报的）接到桥上。以一句话开新一轮时（`deliver`），这一轮开始就是那句开出的，之后的结束照常歇下。
    func event(_ event: TurnEvent, from pid: Int32) {
        if case .exited = event { return processGone(pid) }
        guard let thread = hosted[pid]?.thread, let session = tracked["\(thread).\(pid)"] else { return }
        switch event {
        case .turnStarted:
            session.restarting = nil
            startTurn(session, at: .now)
        case .failed(let text):
            session.lastError = text
            return
        case .turnFinished:
            endTurn(session, failure: session.lastError)
        case .speaking, .context:
            return bridge.show(event, in: session.id)
        case .tool, .toolDone, .exited, .received:
            return
        }
        publish(session)
    }

    /// 出错的原文只在开出线程的连接上（`error` 通知），常驻服务只广播 `systemError`，而且它先于这一轮落定：此刻读 `thread/turns/list`
    /// 偶尔还是 `interrupted`、没有原因（实测，之后没有任何通知再来）。会话文件里这一轮的 `task_complete` 记录带着原文，是落定的标志，
    /// 一定会写：盯着会话文件，等到这一轮的结束记录出现就取原文。
    private func readFailure(_ session: Tracked) {
        guard let file = bridge.session(id: session.id)?.sessionFile else { return }
        session.failureWatch?.cancel()
        session.failureWatch = Task {
            let follower = FileFollower()
            defer { follower.stop() }
            follower.follow(only: [file.realPath.path])
            for await _ in follower.paths {
                guard tracked[session.id] === session, !Task.isCancelled else { return }
                guard let turn = await CodexHistory.lastTurn(in: file), turn.finished else { continue }
                if let failure = turn.failure, session.facts.failure != nil {
                    session.facts.failure = failure
                    publish(session)
                }
                return
            }
        }
    }

    /// 同一进程上还有认不出主人的线程（推送先到、还在问或第一次没读到）时先不歇下：它可能就是这一轮派出的子代理，
    /// 不等就会先报歇下、认出后再进“等子代理”。由这次结束触发一起再问一遍，至多 `AgentTimeouts.settleAsk`：认出的进名册，
    /// 仍读不到、没及时回的等它下一条推送再问（`resolve`）；问完歇下。
    /// 这一轮出错的原因只记在 `facts.failure`，只有新一轮开始（`startTurn`）清空：同一轮后到的结束信号（终端的 idle、Stop、Interrupt）
    /// 不带原因，推迟中、歇下后都不动它。
    func endTurn(_ session: Tracked, failure: String? = nil) {
        release(session)
        guard session.restarting == nil else { session.restarting = .stopped; return }
        if let failure { session.facts.failure = failure }
        guard session.ending == nil else { return }
        let unknown = unresolvedThreads(on: session.pid)
        guard !unknown.isEmpty else { return session.facts.endTurn(failure: session.facts.failure) }
        let pid = session.pid
        session.ending = Task {
            try? await withDeadline(AgentTimeouts.settleAsk, timing: timing, orThrow: CancellationError()) { @MainActor in
                await withTaskGroup { group in
                    for thread in unknown { group.addTask { await self.resolve(thread, pid: pid) } }
                }
            }
            guard !Task.isCancelled, tracked[session.id] === session else { return }
            session.ending = nil
            guard session.restarting == nil else { session.restarting = .stopped; return }
            session.facts.endTurn(failure: session.facts.failure)
            if !session.unread.isEmpty { wake(session) }
            publish(session)
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

    /// `start` 是这一轮开始的时刻，早于它可能的结束：Codex 给的 `Turn.startedAt`，CuePad 补开的是发出的时刻，钩子没有时刻用收到的时刻。开始一轮只经这里。
    func startTurn(_ session: Tracked, at start: Date) {
        session.cancelWaits()
        session.ending = nil
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
    private func resolve(_ thread: String, pid: Int32) async {
        let key = "\(thread).\(pid)"
        if case .unreadable(let queued) = threads[key] { threads[key] = .asking(queued) }
        guard let rpc = hosted[pid]?.rpc ?? daemon.flatMap({ $0.pid == pid ? $0 : nil }) else {
            threads[key] = nil
            return
        }
        guard let info = try? await rpc.call("thread/read", ["threadId": .string(thread)])["thread"] else { return unresolved(key) }
        await register(info, on: rpc)
    }

    private func unresolved(_ key: String) {
        if case .asking(let queued) = threads[key] { threads[key] = .unreadable(queued) }
    }

    func register(_ thread: JSONValue, on rpc: CodexRPC) async {
        guard let child = thread["id"]?.string else { return }
        let key = "\(child).\(rpc.pid)"
        let owner: Owner, last: JSONValue?
        do {
            owner = try await self.owner(of: thread, on: rpc)
            if case .session = owner { last = try await Self.lastTurn(child, on: rpc) } else { last = nil }
        } catch {
            return unresolved(key)
        }
        let running = last?["status"]?.string == "inProgress"
        // 同一线程同时在问的另一次（推送触发的与歇下前的再问）先没读到时，这次读到的照样算
        guard let queued = threads[key]?.pending else { return }
        threads[key] = owner
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
            if method == "item/completed", let item = params["item"], item["type"]?.string == "agentMessage", let text = item["text"]?.string {
                session.lastWords[child] = text
            }
            session.facts.updateSubagent(child, at: now) { $0.progressAt = now }
        }
        publish(session)
    }

    /// 一轮的开始时刻（`Turn.startedAt`，Unix 秒）；没给的（`turn/start` 的回应里是 null）为此刻。
    static func startedAt(_ turn: JSONValue?) -> Date {
        turn?["startedAt"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .now
    }

    /// 线程最近的一轮。接上时在不在跑看它（`inProgress`），不看 `thread/read` 给的线程状态：子代理睡着等（`clock.sleep`）时
    /// 读到的是 idle，它这一轮还没结束（实测）。推送里的 idle 不同，睡着等时不报（见 `notification`）。
    static func lastTurn(_ thread: String, on rpc: CodexRPC) async throws -> JSONValue? {
        try await rpc.call("thread/turns/list", ["threadId": .string(thread), "limit": 1])["data"]?.array?.first
    }

    private static func phase(of turn: JSONValue?) -> PiSubagentPhase {
        switch turn?["status"]?.string {
        case "completed": .done
        case "failed": .failed
        default: .interrupted
        }
    }

    private func settle(_ child: String, _ phase: PiSubagentPhase, summary: String?, in session: Tracked) {
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

    /// 终端会话这一轮发出就算开始（常驻服务不报开始）。空输入的一轮先把子代理的结果取进来再请求模型；带文字的一轮先请求模型，v2 的结果要到之后才取出，模型会答“还没收到”。
    /// 同 Codex 的 `wake_on_agent_messages`（openai/codex#54961，未发布、默认关、不管 v1，发布并默认开启后改用它），边界也照它：
    /// 父线程上一轮被停下、在 Plan 模式、这一批没有交回结果（都被停下）的不补，直接歇下。
    /// 终端里这一轮显示为一段没有提问的回答；它不触发 `UserPromptSubmit`，输入框里打了一半的话不受影响（实测）。
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
            let hostedSession = hosted[session.pid] != nil
            if !hostedSession {
                startTurn(session, at: .now)
                publish(session)
            }
            do {
                try await turnStart(session, [])
            } catch {
                // 没开成：终端会话收回发出时算的开始，托管的这一批不再等，都带着原因歇下
                guard tracked[session.id] === session, session.facts.running != hostedSession else { return }
                session.unread = [:]
                session.facts.inFlight = []
                session.facts.endTurn(failure: error.localizedDescription)
                publish(session)
            }
        }
    }
}
#endif
