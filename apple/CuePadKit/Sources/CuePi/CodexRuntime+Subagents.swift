#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

extension CodexRuntime {
    func notification(_ method: String, _ params: JSONValue, from pid: Int32) {
        // 子代理的线程没有 `thread/started`：报出来的顶层线程不是子代理（Codex 起的临时线程等），之后它的推送不必去问
        if method == "thread/started", let thread = params["thread"], let id = thread["id"]?.string, thread["parentThreadId"]?.string == nil {
            threads["\(id).\(pid)"] = threads["\(id).\(pid)"] ?? .foreign
        }
        guard let threadID = params["threadId"]?.string else { return }
        guard let session = tracked["\(threadID).\(pid)"] else { return child(method, params, thread: threadID, pid: pid) }
        switch method {
        case "thread/name/updated":
            bridge.update(session.id) { $0.name = params["threadName"]?.string }
            return
        case "thread/status/changed":
            switch params["status"]?["type"]?.string {
            // 钩子漏报的歇下（出错的一轮没有 Stop）；钩子的 Stop 晚到也只是再歇一次。睡着等（`clock.sleep`）时不报 idle（托管与终端实测）
            case "idle" where session.facts.running:
                endTurn(session)
            case "systemError":
                endTurn(session, failure: session.lastError ?? "Codex 出错了")
                if session.lastError == nil { readFailure(session) }
            default: return
            }
        case "error" where params["willRetry"]?.bool != true:
            // 出错的原文（常驻服务也广播）；随后的 systemError 或失败的 turn/completed 用它
            session.lastError = CodexModel.failure(of: params)
            return
        // 以下只有开出这个线程的连接（托管的进程）收得到
        case "turn/started":
            session.lastError = nil
            guard !session.facts.running else { return }
            startTurn(session, at: Self.startedAt(params["turn"]))
        case "turn/completed" where params["turn"]?["status"]?.string == "failed":
            // 失败的一轮没有 Stop 钩子，状态停在这里
            endTurn(session, failure: session.lastError ?? CodexModel.failure(of: params["turn"]))
        case "turn/completed":
            guard session.facts.running else { return }
            endTurn(session)
        case "serverRequest/resolved":
            // 服务端请求被别处答了或收回了
            guard case .request = session.reply else { return }
            session.reply = nil
            session.facts.questions = []
        case "thread/closed":
            return detach(session.id)
        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"], let window = usage["modelContextWindow"]?.int else { return }
            let used = usage["last"]?["totalTokens"]?.int
            bridge.update(session.id) { $0.context = PiContextUsage(tokens: used, window: window) }
            return
        default:
            return
        }
        publish(session)
    }

    /// 出错的原文只在开出线程的连接上（`error` 通知），常驻服务只广播 `systemError`：从最近一轮读出它的错误。
    private func readFailure(_ session: Tracked) {
        Task {
            guard let rpc = try? await control(session),
                  let turn = try? await Self.lastTurn(session.threadID, on: rpc), turn["status"]?.string == "failed", tracked[session.id] === session,
                  !session.facts.running else { return }
            session.facts.failure = CodexModel.failure(of: turn)
            publish(session)
        }
    }

    /// 这一轮结束：挂着的钩子收回；CuePad 正以一句话开新一轮时只记下（见 `deliver`），不歇下。
    func endTurn(_ session: Tracked, failure: String? = nil) {
        release(session)
        guard session.restarting == nil else { session.restarting = .stopped; return }
        session.facts.endTurn(failure: failure)
    }

    // MARK: 子代理

    /// 开始新的一轮（`start` 是这一轮开始的时刻，早于它可能的结束：Codex 给的 `Turn.startedAt`，CuePad 补开的是发出的时刻，
    /// 钩子没有时刻用收到的时刻）：歇着时落定的子代理的结果随这一轮交给模型，不再在飞。开始一轮只经这里。
    func startTurn(_ session: Tracked, at start: Date) {
        session.facts.startTurn(at: start)
        session.facts.inFlight.subtract(session.unread.keys)
        session.unread = [:]
    }

    /// 子线程的推送里管生命周期与进展的
    private static let childMethods: Set = ["turn/started", "turn/completed", "thread/status/changed", "item/started", "item/completed"]

    /// 不是会话的线程的推送：子代理的交给它的会话；第一次见的先问 Codex 它是谁的（`register`），问的时候攒着之后的推送。
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
        case nil:
            threads[key] = .asking([(method, params)])
            Task { await resolve(thread, pid: pid) }
        }
    }

    private func resolve(_ thread: String, pid: Int32) async {
        guard let rpc = hosted[pid] ?? daemon.flatMap({ $0.pid == pid ? $0 : nil }),
              let info = try? await rpc.call("thread/read", ["threadId": .string(thread)])["thread"] else {
            threads["\(thread).\(pid)"] = .foreign
            return
        }
        await register(info, on: rpc)
    }

    /// 认下一个线程（`thread/read` 读到的，推送先攒着）：是子代理就补进会话的名册——最近一轮还在跑的算在飞（没赶上它这一轮开始：CuePad 晚启动），
    /// 歇着的按它最近一轮的结果落定（还没跑过的等它开始）；再按先后补上攒着的推送。
    func register(_ thread: JSONValue, on rpc: CodexRPC) async {
        guard let child = thread["id"]?.string else { return }
        let key = "\(child).\(rpc.pid)"
        let owner = await owner(of: thread, on: rpc)
        var last: JSONValue?
        if case .session = owner { last = try? await Self.lastTurn(child, on: rpc) }
        let running = last?["status"]?.string == "inProgress"
        guard case .asking(let queued) = threads[key] else { return }
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

    /// 线程（`thread/read` 读到的）属于哪个会话：顺着 `parentThreadId` 往上找到接着的会话或已认得的子代理（孙代理算进同一个会话）。
    /// 名字是派它时给的任务名（v2 的 `agent_path` 末段），没有就用 Codex 起的昵称。
    private func owner(of thread: JSONValue, on rpc: CodexRPC) async -> Owner {
        let spawn = thread["source"]?["subAgent"]?["thread_spawn"]
        let role = thread["agentRole"]?.string ?? spawn?["agent_role"]?.string ?? "default"
        let path = spawn?["agent_path"]?.string.flatMap { $0.split(separator: "/").last.map(String.init) }
        let name = path ?? thread["agentNickname"]?.string ?? role
        var current = thread
        while let parent = current["parentThreadId"]?.string {
            let key = "\(parent).\(rpc.pid)"
            if let session = tracked[key] { return .session(session.id, name: name, role: role) }
            if case .session(let id, _, _) = threads[key] { return .session(id, name: name, role: role) }
            guard let up = try? await rpc.call("thread/read", ["threadId": .string(parent)])["thread"] else { break }
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

    /// 一轮的结束状态（`Turn.status`）→ 子代理落定的样子
    private static func phase(of turn: JSONValue?) -> PiSubagentPhase {
        switch turn?["status"]?.string {
        case "completed": .done
        case "failed": .failed
        default: .interrupted
        }
    }

    /// 子代理落定：父线程这一轮在跑，结果并进这一轮；歇着就等这一批都落定再补一轮。已经落定的（一轮结束后又卸载）不再算。
    private func settle(_ child: String, _ phase: PiSubagentPhase, summary: String?, in session: Tracked) {
        guard session.facts.inFlight.contains(child), session.unread[child] == nil else { return }
        session.facts.settleSubagent(child, phase, summary: summary, at: .now)
        session.lastWords[child] = nil
        if session.facts.running {
            session.facts.inFlight.remove(child)
        } else {
            session.unread[child] = phase != .interrupted
            wake(session)
        }
    }

    /// 最后一个在跑的子代理落定、父线程歇着：补一轮空输入，这一轮发出就算开始，它做完才歇下。空输入的一轮先把子代理的结果取进来再请求模型；
    /// 带文字的一轮先请求模型，v2 的结果要到之后才取出，模型会答"还没收到"。
    /// 同 Codex 的 `wake_on_agent_messages`（openai/codex#54961，未发布、默认关、不管 v1，发布并默认开启后改用它），边界也照它：
    /// 父线程上一轮被停下、在 Plan 模式、这一批没有交回结果（都被停下）的不补，直接歇下。补的这一轮在跑时你说话，照常先停下它再开你那一轮（`deliver`）。
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
            session.unread = [:]
            session.facts.inFlight = []
            guard delivered, last?.plan != true, last?.interrupted != true else { return publish(session) }
            startTurn(session, at: .now)
            publish(session)
            do {
                try await control(session).call("turn/start", ["threadId": .string(session.threadID), "input": []])
            } catch {
                guard tracked[session.id] === session, session.facts.running else { return }
                session.facts.endTurn(failure: error.localizedDescription)
                publish(session)
            }
        }
    }
}
#endif
