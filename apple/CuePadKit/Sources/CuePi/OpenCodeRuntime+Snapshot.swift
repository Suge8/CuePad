#if os(macOS)
import CueStore
import Foundation

extension OpenCodeRuntime {
    func snapshot(_ connection: Connection) async throws {
        let client = connection.client
        let all = try await client.sessions().filter { !$0.isCueBrain }
        let asked = Date.now  // 对话里读不到一轮时的开始：快照里在跑的那一轮此刻之后才收尾
        let active = Set(try await client.get(OpenCodeData<[String: OpenCodeActive]>.self, "/api/session/active").data.keys)
        var started: [String: Date] = [:]
        for info in all where info.parentID == nil && active.contains(info.id) {
            let read = try await OpenCodeHistory.read(client, info, from: try await checkpoint(of: info.id), files: store.files)
            started[info.id] = read.checkpoint.history.lastTurnStart ?? asked
        }
        guard self.connection === connection else { return }
        childTurns = [:]

        let topLevel = all.filter { $0.parentID == nil }
        for info in topLevel {
            var tracked = sessions[info.id] ?? Tracked(info: info)
            tracked.info = info
            // 断线期间错过的事件不补：执行与压缩的进展只认此刻的快照（在线会话的压缩中与出错原文由 refreshLive 补上）
            // 快照里在跑的一轮：开始取快照之后读到的对话里的（可能是断线期间开始的另一轮，`SessionFacts.startTurn(at:)`）
            if let start = started[info.id] { tracked.facts.startTurn(at: start) } else { tracked.facts.running = false }
            tracked.facts.work(.thinking)
            if tracked.turn.speaking { bridge.setDraft(bridgeID(info.id, connection), nil) }
            tracked.turn = OpenCodeTurn()
            tracked.facts.compacting = false
            tracked.facts.failure = !tracked.facts.running && info.outcome == "failed" ? OpenCodeTurn.unknownFailure : nil
            if tracked.facts.running || info.updatedAt >= connection.startedAt, ended[info.id].map({ info.updatedAt > $0 }) ?? true {
                tracked.online = true
            }
            sessions[info.id] = tracked
        }
        let present = Set(topLevel.map(\.id))
        for (id, tracked) in sessions where !present.contains(id) {
            if tracked.online { bridge.detach(bridgeID(id, connection), reason: .closed(reason: "deleted")) }
            sessions[id] = nil
        }
        for child in all where child.parentID != nil && child.updatedAt >= connection.startedAt {
            guard let parent = child.parentID, sessions[parent] != nil else { continue }
            parents[child.id] = parent
            let phase: PiSubagentPhase = if active.contains(child.id) { .running } else {
                switch child.outcome {
                case "failed": .failed
                case "interrupted": .interrupted
                default: .done
                }
            }
            subagent(child.id, of: parent) { agent in
                agent.phase = .known(phase)
                agent.startedAt = child.createdAt
                agent.settledAt = phase == .running ? nil : child.updatedAt
                agent.name = child.title ?? ""
                agent.role = child.agent ?? ""
            }
        }
        for (id, tracked) in sessions where tracked.online { try await refreshLive(id, tracked, client) }
        guard self.connection === connection else { return }
        for (id, tracked) in sessions where tracked.online && tracked.firstMessage == nil {
            sessions[id]?.firstMessage = try await checkpoint(of: id)?.history.firstMessage
        }
        guard self.connection === connection else { return }
        listed = present
        connection.ready = true
        for (id, tracked) in sessions where tracked.online { publish(id) }
        for waiter in waiters.values { waiter.resume(returning: connection) }
        waiters = [:]
        Task { await backfill(topLevel, connection) }
    }

    /// 在线会话此刻要的另几样：待答的权限与表单、上下文用量、工作目录的模型与命令。
    private func refreshLive(_ id: String, _ tracked: Tracked, _ client: OpenCodeClient) async throws {
        var permissions: [OpenCodePermission] = [], forms: [OpenCodeForm] = []
        let running = tracked.facts.subagents.filter { $0.state.phase == .known(.running) }.map(\.id)
        for asker in [id] + running {
            permissions += try await client.get(OpenCodeData<[OpenCodePermission]>.self, "/api/session/\(asker)/permission").data
            forms += try await client.get(OpenCodeData<[OpenCodeForm]>.self, "/api/session/\(asker)/form").data
        }
        let last = try await client.get(OpenCodePage<OpenCodeMessage>.self, "/api/session/\(id)/message?type=assistant&limit=1").data.first
        // 压缩开始与结束之间，最近一条压缩消息是 running：断线时错过了开始事件，从它恢复"压缩中"
        let compaction = try await client.get(OpenCodePage<OpenCodeMessage>.self, "/api/session/\(id)/message?type=compaction&limit=1").data.first
        try await catalog(tracked.directory, client)
        sessions[id]?.facts.questions = permissions.map(Self.question) + forms.map(Self.question)
        let window = OpenCodeTurn.window(of: last?.model, in: catalogs[tracked.directory]?.models ?? [])
        sessions[id]?.context = window.map { PiContextUsage(tokens: last?.tokens?.prompt, window: $0) }
        sessions[id]?.facts.compacting = compaction?.status == "running"
        if tracked.info.model == nil { sessions[id]?.info.model = last?.model }
        if tracked.facts.failure != nil, let error = last?.error?.message { sessions[id]?.facts.failure = error }
    }

    /// 工作目录的模型与命令（没取过才取）。
    @discardableResult
    func catalog(_ directory: String, _ client: OpenCodeClient, reload: Bool = false) async throws -> Catalog {
        if !reload, let catalog = catalogs[directory] { return catalog }
        let models = try await client.get(OpenCodeData<[OpenCodeModel]>.self, "/api/model", directory: directory).data
        let commands = try await client.get(OpenCodeData<[OpenCodeCommand]>.self, "/api/command", directory: directory).data
        let catalog = Catalog(
            models: models,
            commands: [PiSlashCommand(name: Self.compact, summary: String(localized: "压缩上下文"), source: .known(.builtin))]
                + commands.map { PiSlashCommand(name: $0.name, summary: $0.description.map { String($0.prefix(120)) }, source: .known(.prompt)) })
        catalogs[directory] = catalog
        return catalog
    }

    static let compact = "compact"

    func bridgeID(_ sessionID: String, _ connection: Connection) -> PiSession.ID { "\(sessionID).\(connection.pid)" }

    /// 把一个会话此刻的样子交给桥：在线的上桥或更新，不在线的不动（下线由调用方 `detach`）。
    func publish(_ sessionID: String) {
        guard let connection, connection.ready, var tracked = sessions[sessionID], tracked.online else { return }
        let id = bridgeID(sessionID, connection)
        let catalog = catalogs[tracked.directory]
        let model = tracked.info.model.map { ref in
            catalog?.models.first { $0.key == PiModelKey(provider: ref.providerID, id: ref.id) }?.option
                ?? PiModelOption(key: PiModelKey(provider: ref.providerID, id: ref.id), name: ref.id, thinkingLevels: [.off])
        }
        func fill(_ session: inout PiSession) {
            tracked.facts.publish(to: &session)
            session.name = tracked.info.title
            session.firstMessage = tracked.firstMessage
            session.launchToken = tracked.launchToken
            session.hosted = tracked.hosted
            session.model = model
            session.thinking = model.flatMap { Self.thinking(tracked.info.model?.variant, of: $0) }
            session.availableModels = catalog?.models.map(\.option) ?? []
            session.context = tracked.context
            session.commands = catalog?.commands ?? []
        }
        if bridge.session(id: id) == nil {
            var session = PiSession(
                id: id, sessionID: sessionID, agent: .opencode, sessionFile: nil, pid: connection.pid,
                cwd: URL(filePath: tracked.directory, directoryHint: .isDirectory), terminal: PiTerminal(),
                state: .settled, stateSince: .now)
            fill(&session)
            bridge.attach(session, via: self)
        } else {
            bridge.update(id, fill)
        }
        sessions[sessionID] = tracked
    }

    /// 强度是模型的 `variant`；没设（`default`）时，没有强度可选的模型是 `off`，有的不知道是哪一档。
    static func thinking(_ variant: String?, of model: PiModelOption) -> Open<PiThinkingLevel>? {
        guard let variant, variant != "default" else { return model.thinkingLevels == [.off] ? .known(.off) : nil }
        return Open(rawValue: variant)
    }
}
#endif
