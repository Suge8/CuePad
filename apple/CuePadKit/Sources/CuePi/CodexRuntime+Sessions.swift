#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

extension CodexRuntime {
    /// 常驻服务的控制 socket：`codex app-server daemon version` 在服务跑着时给出它；没跑为 nil（之后再问）。
    private func daemonSocket() async -> String? {
        if let controlSocket { return controlSocket }
        guard let codex = try? await executable(),
              let result = await ChildProcess.run(codex.url, ["app-server", "daemon", "version"], environment: codex.environment, timeout: AgentTimeouts.command, timing: timing),
              let info = JSONValue.parse(Data(result.output.utf8)), info["status"]?.string == "running", let path = info["socketPath"]?.string
        else { return nil }
        controlSocket = path
        return path
    }

    /// 连上常驻服务（已连着就用那条）；服务没跑为 nil。
    private func daemonConnection() async throws -> CodexRPC? {
        if let daemon, !daemon.isClosed { return daemon }
        if let connecting { return try await connecting.value }
        guard let path = await daemonSocket() else { return nil }
        let task = Task { try await CodexRPC.connect(socket: path) }
        connecting = task
        defer { connecting = nil }
        let rpc = try await task.value
        let pid = rpc.pid
        rpc.onNotification = { [weak self] method, params in self?.notification(method, params, from: pid) }
        rpc.onClose = { [weak self, weak rpc] in
            if let self, self.daemon === rpc { self.daemon = nil }
        }
        daemon = rpc
        watchExit(pid)
        return rpc
    }

    /// 启动时把常驻服务里已经载入的线程接上（CuePad 晚于终端里的会话启动）：会话先接上，子代理的线程再补进它们的名册。
    func discover() async {
        do {
            guard let rpc = try await daemonConnection() else { return }
            let loaded = try await rpc.call("thread/loaded/list", [:])
            var children: [JSONValue] = []
            for threadID in loaded["data"]?.array?.compactMap(\.string) ?? [] where tracked["\(threadID).\(rpc.pid)"] == nil {
                // Codex 自己起的临时线程（起标题等）不是会话
                guard let thread = try await rpc.call("thread/read", ["threadId": .string(threadID)])["thread"],
                      thread["ephemeral"]?.bool != true else { continue }
                if thread["parentThreadId"]?.string != nil {
                    children.append(thread)
                } else if scope.covers(sessionID: threadID) {
                    try await adopt(thread, on: rpc)
                }
            }
            for child in children {
                guard let id = child["id"]?.string, threads["\(id).\(rpc.pid)"] == nil else { continue }
                threads["\(id).\(rpc.pid)"] = .asking([])
                await register(child, on: rpc)
            }
        } catch {
            Self.log.notice("没能读出常驻服务里的会话：\(String(describing: error))")
        }
    }

    func adoptFromDaemon(_ threadID: String) async throws -> PiSession.ID? {
        guard let rpc = try? await daemonConnection() else { return nil }
        let loaded = try await rpc.call("thread/loaded/list", [:])
        guard loaded["data"]?.array?.contains(.string(threadID)) == true,
              let thread = try await rpc.call("thread/read", ["threadId": .string(threadID)])["thread"],
              thread["parentThreadId"]?.string == nil, thread["ephemeral"]?.bool != true else { return nil }
        return try await adopt(thread, on: rpc)
    }

    /// 接上一个线程（`thread/read` 读到的，不是子代理）。
    @discardableResult
    private func adopt(_ thread: JSONValue, on rpc: CodexRPC) async throws -> PiSession.ID {
        let threadID = thread["id"]?.string ?? ""
        let id = "\(threadID).\(rpc.pid)"
        if tracked[id] != nil { return id }
        // 正在跑一轮：接上时就是工作中（钩子要等下一个事件才来），从这一轮的开始算
        let last = try await Self.lastTurn(threadID, on: rpc)
        let running = last?["status"]?.string == "inProgress"
        if tracked[id] != nil { return id }
        // thread/read 不返回 serviceTier；resume 虽然返回，却会订阅线程并接走终端的审批，所以保持未知。
        attach(makeSession(thread, pid: rpc.pid)) { session in
            if running { self.startTurn(session, at: Self.startedAt(last)) }
        }
        return id
    }

    // MARK: 会话

    func makeSession(_ thread: JSONValue, pid: Int32) -> PiSession {
        let threadID = thread["id"]?.string ?? ""
        var session = PiSession(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex, sessionFile: thread["path"]?.string.map { URL(filePath: $0) },
            pid: pid, cwd: URL(filePath: thread["cwd"]?.string ?? "/", directoryHint: .isDirectory), terminal: PiTerminal(),
            state: .settled, stateSince: .now)
        apply(thread, to: &session)
        return session
    }

    /// 线程的名字、首条消息、模型与强度写进快照（`thread/read`、`thread/start`、`thread/resume` 给的都是这个形状）。
    func apply(_ thread: JSONValue, to session: inout PiSession) {
        session.name = thread["name"]?.string
        if let preview = thread["preview"]?.string, !preview.isEmpty { session.firstMessage = String(preview.prefix(PiSessionName.firstMessageLimit)) }
        if let model = thread["model"]?.string {
            session.model = models?.first { $0.id == model }?.option
                ?? PiModelOption(key: PiModelKey(provider: CodexModel.provider, id: model), name: model, thinkingLevels: [])
            session.availableModels = (models ?? []).map(\.option)
        }
        session.thinking = thread["reasoningEffort"]?.string.map(CodexModel.thinking)
    }

    func attach(_ session: PiSession, prepare: (Tracked) -> Void = { _ in }) {
        let entry = Tracked(id: session.id, threadID: session.sessionID, pid: session.pid)
        prepare(entry)
        tracked[session.id] = entry
        var session = session
        entry.facts.publish(to: &session)
        bridge.attach(session, via: self)
        watchExit(session.pid)
        refresh(session.id, skills: true)
    }

    private func watchExit(_ pid: Int32) {
        guard exitWatchers[pid] == nil else { return }
        exitWatchers[pid] = ProcessExitWatcher(pid: pid) { [weak self] in self?.processGone(pid) }
    }

    /// 承载进程退出了：它上面的会话都下线。
    func processGone(_ pid: Int32) {
        exitWatchers.removeValue(forKey: pid)?.cancel()
        hosted[pid] = nil
        marks = marks.filter { $0.value != pid }
        threads = threads.filter { !$0.key.hasSuffix(".\(pid)") }
        for session in tracked.values where session.pid == pid { detach(session.id) }
    }

    func detach(_ id: PiSession.ID) {
        guard let session = tracked.removeValue(forKey: id) else { return }
        threads = threads.filter { if case .session(id, _, _) = $0.value { false } else { true } }
        release(session)
        bridge.detach(id, reason: .closed(reason: "quit"))
    }

    /// 从 Codex 重新读名字、模型与强度（`thread/read`），可换的模型（`model/list`）与 skill（`skills/list`，斜杠命令）。
    func refresh(_ id: PiSession.ID, skills: Bool = false) {
        Task {
            do {
                guard let session = tracked[id] else { return }
                let rpc = try await control(session)
                if models == nil { models = try await CodexModel.list(rpc) }
                if skills, let cwd = bridge.session(id: id)?.cwd {
                    let listed = try await rpc.call("skills/list", ["cwds": [.string(cwd.path)]])
                    let entries = (listed["data"]?.array?.first?["skills"]?.array ?? []).filter { $0["enabled"]?.bool != false }
                    session.skills = entries.compactMap { entry in entry["name"]?.string.flatMap { name in entry["path"]?.string.map { (name, $0) } } }
                    let modes = hosted[session.pid] == nil ? [] : Self.modeCommands
                    let commands = Self.builtinCommands + modes + entries.compactMap { entry -> PiSlashCommand? in
                        guard let name = entry["name"]?.string else { return nil }
                        return PiSlashCommand(name: "skill:\(name)", summary: entry["description"]?.string.map { $0.clipped(ToolDetail.limit) }, source: .known(.skill))
                    }
                    bridge.update(id) { $0.commands = commands }
                }
                let read = try await rpc.call("thread/read", ["threadId": .string(session.threadID)])
                guard let thread = read["thread"] else { return }
                bridge.update(id) { self.apply(thread, to: &$0) }
            } catch {
                Self.log.notice("没能读出 Codex 会话的设置：\(String(describing: error))")
            }
        }
    }

    /// 能从 CuePad 执行的内置命令：Codex 的斜杠命令是终端界面自己实现的，只有这几个有对应的接口。
    private static let builtinCommands = [
        PiSlashCommand(name: "compact", summary: String(localized: "压缩上下文"), source: .known(.builtin)),
        PiSlashCommand(name: "name", summary: String(localized: "给会话改名"), source: .known(.builtin), hint: String(localized: "<名字>")),
        PiSlashCommand(name: "model", summary: String(localized: "换模型"), source: .known(.builtin), hint: String(localized: "<模型>")),
    ]

    /// 托管会话切协作模式（终端会话的模式归终端界面管）
    private static let modeCommands = [
        PiSlashCommand(name: "plan", summary: String(localized: "进 Plan 模式：先问清楚、出计划，不动手"), source: .known(.builtin), hint: String(localized: "[话]")),
        PiSlashCommand(name: "default", summary: String(localized: "回默认模式"), source: .known(.builtin)),
    ]

    /// 会话的控制通道：托管的是它的进程，终端里的是常驻服务（钩子的父进程就是它才算；`codex exec` 之类没有控制接口）。
    func control(_ session: Tracked) async throws -> CodexRPC {
        if let rpc = hosted[session.pid]?.rpc { return rpc }
        guard let rpc = try await daemonConnection(), rpc.pid == session.pid else { throw PiBridgeError.unsupported }
        return rpc
    }

    func publish(_ session: Tracked) {
        bridge.update(session.id) { session.facts.publish(to: &$0) }
    }
}
#endif
