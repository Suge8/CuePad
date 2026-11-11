#if os(macOS)
import CueStore
import Foundation

extension OpenCodeRuntime {
    func snapshot(_ connection: Connection) async throws {
        let client = connection.client
        let hosted = try await store.hostedSessionIDs(of: .opencode, host: hostID).union(sessions.keys)
        let all = try await client.sessions().filter { hosted.contains($0.parentID ?? $0.id) }
        let asked = Date.now  // 对话里读不到一轮时的开始：快照里在跑的那一轮此刻之后才收尾
        let active = Set(try await client.get(OpenCodeData<[String: JSONValue]>.self, "/api/session/active").data.keys)
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
            if tracked.facts.running || info.updatedAt >= connection.startedAt, revives(info.id, at: info.updatedAt) {
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
            let phase: SubagentPhase = if active.contains(child.id) { .running } else {
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
        sessions[id]?.context = window.map { ContextUsage(tokens: last?.tokens?.prompt, window: $0) }
        sessions[id]?.facts.compacting = compaction?.status == "running"
        if tracked.info.model == nil { sessions[id]?.info.model = last?.model }
        if tracked.facts.failure != nil, let error = last?.error?.message { sessions[id]?.facts.failure = error }
    }

    @discardableResult
    func catalog(_ directory: String, _ client: OpenCodeClient, reload: Bool = false) async throws -> Catalog {
        if !reload, let catalog = catalogs[directory] { return catalog }
        let models = try await client.get(OpenCodeData<[OpenCodeModel]>.self, "/api/model", directory: directory).data
        let commands = try await client.get(OpenCodeData<[OpenCodeCommand]>.self, "/api/command", directory: directory).data
        let catalog = Catalog(
            models: models,
            commands: [SlashCommand(name: Self.compact, summary: String(localized: "压缩上下文"), source: .known(.builtin))]
                + commands.map { SlashCommand(name: $0.name, summary: $0.description.map { String($0.prefix(120)) }, source: .known(.prompt)) })
        catalogs[directory] = catalog
        return catalog
    }

    static let compact = "compact"

    /// 不在线的会话这一刻（服务的时钟，与 CuePad 同机）有活动是否让它上线：在 CuePad 里结束过的，只认结束之后的。
    /// 事件流比请求的回应晚到：结束之前开会话、发出那句话的事件常在结束之后才到，不能把它又拉回桥上。
    func revives(_ sessionID: String, at time: Date) -> Bool {
        ended[sessionID].map { time > $0 } ?? true
    }

    func bridgeID(_ sessionID: String, _ connection: Connection) -> Session.ID { "\(sessionID).\(connection.pid)" }

    func publish(_ sessionID: String) {
        guard let connection, connection.ready, var tracked = sessions[sessionID], tracked.online else { return }
        let id = bridgeID(sessionID, connection)
        let catalog = catalogs[tracked.directory]
        let model = tracked.info.model.map { ref in
            catalog?.models.first { $0.key == ModelKey(provider: ref.providerID, id: ref.id) }?.option
                ?? ModelOption(key: ModelKey(provider: ref.providerID, id: ref.id), name: ref.id, thinkingLevels: [.off])
        }
        func fill(_ session: inout Session) {
            tracked.facts.publish(to: &session)
            session.name = tracked.info.title
            session.firstMessage = tracked.firstMessage
            session.launchToken = tracked.launchToken
            session.hosted = true
            session.model = model
            session.thinking = model.flatMap { Self.thinking(tracked.info.model?.variant, of: $0) }
            session.availableModels = catalog?.models.map(\.option) ?? []
            session.context = tracked.context
            session.commands = catalog?.commands ?? []
        }
        if bridge.session(id: id) == nil {
            var session = Session(
                id: id, sessionID: sessionID, agent: .opencode, sessionFile: nil, pid: connection.pid,
                cwd: URL(filePath: tracked.directory, directoryHint: .isDirectory), terminal: TerminalIdentity(),
                state: .settled, stateSince: .now)
            fill(&session)
            bridge.attach(session, via: self)
        } else {
            bridge.update(id, fill)
        }
        sessions[sessionID] = tracked
    }

    /// 强度是模型的 `variant`；没设（`default`）时，没有强度可选的模型是 `off`，有的不知道是哪一档。
    static func thinking(_ variant: String?, of model: ModelOption) -> Open<ThinkingLevel>? {
        guard let variant, variant != "default" else { return model.thinkingLevels == [.off] ? .known(.off) : nil }
        return Open(rawValue: variant)
    }
}
#endif
