#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

extension CodexRuntime {
    func makeSession(_ thread: JSONValue, pid: Int32) -> Session {
        let threadID = thread["id"]?.string ?? ""
        var session = Session(
            id: "\(threadID).\(pid)", sessionID: threadID, agent: .codex, sessionFile: thread["path"]?.string.map { URL(filePath: $0) },
            pid: pid, cwd: URL(filePath: thread["cwd"]?.string ?? "/", directoryHint: .isDirectory), terminal: TerminalIdentity(),
            state: .settled, stateSince: .now)
        apply(thread, to: &session)
        return session
    }

    /// `settings` 为 false 时不取线程上的模型与强度，只按模型清单重认此刻的模型：会话订阅着线程，它的模型与强度只认开线程时的回应、
    /// `thread/settings/updated` 与 Codex 接受了的改动（`configure`）——`thread/settings/update` 只回“已排队”，紧接着读线程可能读到改之前的。
    func apply(_ thread: JSONValue, to session: inout Session, settings: Bool = true) {
        session.name = thread["name"]?.string
        if let preview = thread["preview"]?.string, !preview.isEmpty { session.firstMessage = String(preview.prefix(SessionName.firstMessageLimit)) }
        guard settings else {
            if let model = session.model?.key.id { session.model = option(model) }
            session.availableModels = (models ?? []).map(\.option)
            return
        }
        if let model = thread["model"]?.string {
            session.model = option(model)
            session.availableModels = (models ?? []).map(\.option)
        }
        session.thinking = thread["reasoningEffort"]?.string.map(CodexModel.thinking)
    }

    func option(_ model: String) -> ModelOption {
        models?.first { $0.id == model }?.option ?? ModelOption(key: ModelKey(provider: CodexModel.provider, id: model), name: model, thinkingLevels: [])
    }

    func attach(_ session: Session, driver: CodexDriver) {
        let entry = Tracked(id: session.id, threadID: session.sessionID, driver: driver, pid: session.pid)
        tracked[session.id] = entry
        var session = session
        entry.facts.publish(to: &session)
        bridge.attach(session, via: self)
        refresh(session.id, skills: true)
    }

    func processGone(_ pid: Int32) {
        hosted[pid] = nil
        threads = threads.filter { !$0.key.hasSuffix(".\(pid)") }
        for session in tracked.values where session.pid == pid { detach(session.id) }
    }

    func detach(_ id: Session.ID) {
        guard let session = tracked.removeValue(forKey: id) else { return }
        session.ending?.cancel()
        threads = threads.filter { if case .session(id, _, _) = $0.value { false } else { true } }
        session.reply = nil
        bridge.detach(id, reason: .closed(reason: "quit"))
    }

    func refresh(_ id: Session.ID, skills: Bool = false) {
        Task {
            do {
                guard let session = tracked[id] else { return }
                let rpc = try control(session)
                if models == nil { models = try await CodexModel.list(rpc) }
                if skills, let cwd = bridge.session(id: id)?.cwd {
                    let listed = try await rpc.call("skills/list", ["cwds": [.string(cwd.path)]])
                    let entries = (listed["data"]?.array?.first?["skills"]?.array ?? []).filter { $0["enabled"]?.bool != false }
                    session.skills = entries.compactMap { entry in entry["name"]?.string.flatMap { name in entry["path"]?.string.map { (name, $0) } } }
                    let commands = Self.builtinCommands + entries.compactMap { entry -> SlashCommand? in
                        guard let name = entry["name"]?.string else { return nil }
                        return SlashCommand(name: "skill:\(name)", summary: entry["description"]?.string.map { $0.clipped(ToolDetail.limit) }, source: .known(.skill))
                    }
                    bridge.update(id) { $0.commands = commands }
                }
                let read = try await rpc.call("thread/read", ["threadId": .string(session.threadID)])
                guard let thread = read["thread"] else { return }
                bridge.update(id) { self.apply(thread, to: &$0, settings: false) }
            } catch {
                Self.log.notice("没能读出 Codex 会话的设置：\(String(describing: error))")
            }
        }
    }

    /// 能从 CuePad 执行的内置命令：Codex 的斜杠命令是终端界面自己实现的，只有这几个有对应的接口（`plan`、`default` 切协作模式）。
    private static let builtinCommands = [
        SlashCommand(name: "compact", summary: String(localized: "压缩上下文"), source: .known(.builtin)),
        SlashCommand(name: "name", summary: String(localized: "给会话改名"), source: .known(.builtin), hint: String(localized: "<名字>")),
        SlashCommand(name: "model", summary: String(localized: "换模型"), source: .known(.builtin), hint: String(localized: "<模型>")),
        SlashCommand(name: "plan", summary: String(localized: "进 Plan 模式：先问清楚、出计划，不动手"), source: .known(.builtin), hint: String(localized: "[话]")),
        SlashCommand(name: "default", summary: String(localized: "回默认模式"), source: .known(.builtin)),
    ]

    func control(_ session: Tracked) throws -> CodexRPC {
        guard let rpc = session.driver.rpc else { throw HostedSessionError.notRunning }
        return rpc
    }

    func publish(_ session: Tracked) {
        bridge.update(session.id) { session.facts.publish(to: &$0) }
    }
}
#endif
