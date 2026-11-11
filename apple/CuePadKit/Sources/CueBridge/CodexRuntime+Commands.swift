#if os(macOS)
import CueStore
import CueText
import Foundation

extension CodexRuntime {
    public func send(_ message: SessionMessage, in id: Session.ID) async throws {
        guard let session = tracked[id] else { throw BridgeError.unknownSession(id) }
        try await deliver(Self.input(message.text, images: message.images, skills: session.skills), clientID: CodexHistory.clientID(for: message.deliveryID), to: session)
    }

    /// 以这个会话的 `/skill:名字` 开头的是用这个技能说的——技能条目在前、其余的话在后（同在 Codex 里选了技能再打字），投送请求 id 照样随这条消息进会话文件；名字不是它的技能的照原文。
    static func input(_ text: String, images: [MessageImage], skills: [(name: String, path: String)]) -> [JSONValue] {
        let head = text.prefix { !$0.isWhitespace }
        guard head.hasPrefix("/skill:"), let skill = skills.first(where: { "/skill:\($0.name)" == head }) else {
            return CodexRPC.input(text: text, images: images)
        }
        let rest = text.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return [["type": "skill", "name": .string(skill.name), "path": .string(skill.path)]] + CodexRPC.input(text: rest, images: images)
    }

    /// 以这句开新一轮：在跑就先停下这一轮。停下等这一轮真的中止了才回（`CodexDriver.interrupt`），
    /// 所以紧接着的 `turn/start` 开的是新一轮——它碰上还在跑的一轮会变成插话（压缩那一轮则拒收）。
    /// 被停下的那一轮不报歇下（`restarting`）：这句开出的新一轮从驱动报的开始算（见 `event`），没开成才歇下。
    /// 中止（`abort`）只取消停下上一轮那一段（`StopPhase`）；`turn/start` 发出后的等待不取消：话已交出，抛取消会误报未确认、引起重发。
    func deliver(_ input: [JSONValue], clientID: String, to session: Tracked) async throws {
        // 代次：几处并发进来（发话、带话的斜杠命令、回答问题）时，后来的接手 `restarting`，先到的结束时不清、也不据它判断
        session.restartGeneration += 1
        let mine = session.restartGeneration
        session.restarting = .stopping
        defer { if session.restartGeneration == mine { session.restarting = nil } }
        do {
            try await session.stopPhase.run { [self] in try await interrupt(session) }
            try await turnStart(session, input, options: ["clientUserMessageId": .string(clientID)])
        } catch {
            if session.restartGeneration == mine, session.restarting == .stopped { session.facts.endTurn() }
            publish(session)
            throw error
        }
    }

    public func command(_ line: String, deliveryID _: String?, in id: Session.ID) async throws {
        guard let session = tracked[id] else { throw BridgeError.unknownSession(id) }
        guard line.hasPrefix("/") else { throw BridgeError.rejected("bad_request") }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
        let name = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "compact":
            try await call(session, "thread/compact/start", ["threadId": .string(session.threadID)])
        case "name":
            guard !argument.isEmpty else { throw BridgeError.rejected("missing_argument") }
            try await configure(SessionConfig(name: argument), in: id)
        case "model":
            guard !argument.isEmpty else { throw BridgeError.rejected("missing_argument") }
            try await configure(SessionConfig(model: ModelKey(provider: CodexModel.provider, id: argument)), in: id)
        case "plan", "default":
            try await collaborate(name == "plan" ? "plan" : "default", in: session)
            if !argument.isEmpty {
                try await deliver(CodexRPC.input(text: argument, images: []), clientID: CodexHistory.clientID(for: nil), to: session)
            }
        case _ where name.hasPrefix("skill:"):
            guard session.skills.contains(where: { "skill:\($0.name)" == name }) else { throw BridgeError.rejected("unknown_command") }
            try await deliver(Self.input(line, images: [], skills: session.skills), clientID: CodexHistory.clientID(for: nil), to: session)
        default:
            throw BridgeError.rejected("unknown_command")
        }
    }

    /// 实验接口。模型与强度照会话此刻的，说明用这个模式内置的。
    private func collaborate(_ mode: String, in session: Tracked) async throws {
        let current = bridge.session(id: session.id)
        guard let model = current?.model?.key.id else { throw BridgeError.rejected("failed: " + String(localized: "不知道这个会话用的模型")) }
        var settings: [String: JSONValue] = ["model": .string(model), "developer_instructions": .null]
        if case .known(let level)? = current?.thinking { settings["reasoning_effort"] = .string(CodexModel.effort(level)) }
        try await call(session, "thread/settings/update", [
            "threadId": .string(session.threadID), "collaborationMode": ["mode": .string(mode), "settings": .object(settings)],
        ])
    }

    public func abort(_ id: Session.ID) async throws {
        guard let session = tracked[id] else { throw BridgeError.unknownSession(id) }
        session.stopPhase.cancelAll()
        try await interrupt(session)
    }

    private func interrupt(_ session: Tracked) async throws {
        do {
            try await session.driver.interrupt()
        } catch CodexRPCError.server(_, let message) {
            throw BridgeError.rejected("failed: \(message)")
        }
    }

    public func configure(_ config: SessionConfig, in id: Session.ID) async throws {
        let model = config.model, thinking = config.thinking, name = config.name
        guard let session = tracked[id] else { throw BridgeError.unknownSession(id) }
        if let name {
            try await call(session, "thread/name/set", ["threadId": .string(session.threadID), "name": .string(name)])
            bridge.update(id) { $0.name = name }
        }
        guard model != nil || thinking != nil || config.fast != nil else { return }
        let rpc = try control(session)
        if models == nil { models = try await CodexModel.list(rpc) }
        let target = model?.id ?? bridge.session(id: id)?.model?.key.id
        let entry = models?.first { $0.id == target }
        if model != nil, entry == nil { throw BridgeError.unknownModel(.codex) }
        if config.fast == true, entry?.supportsFast != true { throw BridgeError.unsupported }
        var settings: [String: JSONValue] = ["threadId": .string(session.threadID)]
        if let model { settings["model"] = .string(model.id) }
        if let thinking { settings["effort"] = .string(CodexModel.effort(thinking.clamped(to: entry?.efforts ?? []))) }
        if let fast = config.fast { settings["serviceTier"] = fast ? "priority" : "default" }
        else if model != nil, entry?.supportsFast == false, bridge.session(id: id)?.fast != false { settings["serviceTier"] = "default" }
        try await call(session, "thread/settings/update", .object(settings))
        // 回应只说排进了队（0.167 源码注释：要等 `thread/settings/updated`），这时读线程实测（负载高时）一成多还是改之前的：照它接受的显示，托管会话随那条通知校正
        bridge.update(id) { s in
            if model != nil, let entry { s.model = entry.option }
            if let effort = settings["effort"]?.string { s.thinking = CodexModel.thinking(effort) }
            if let tier = settings["serviceTier"]?.string { s.fast = tier == "priority" }
        }
    }

    /// 这一刻下桥，`tracked` 留到进程退出：停下这一轮还要用它。
    public func end(_ id: Session.ID) throws {
        guard tracked[id] != nil else { throw BridgeError.unknownSession(id) }
        processes.retire(id, link: self)
    }

    func turnStart(_ session: Tracked, _ input: [JSONValue], options: [String: JSONValue] = [:]) async throws {
        session.sentAt = .now
        do {
            try await session.driver.startTurn(input, options: options)
        } catch {
            session.sentAt = nil
            if case CodexRPCError.server(_, let message) = error { throw BridgeError.rejected("failed: \(message)") }
            throw error
        }
    }

    func call(_ session: Tracked, _ method: String, _ params: JSONValue) async throws {
        do {
            try await control(session).call(method, params)
        } catch CodexRPCError.server(_, let message) {
            throw BridgeError.rejected("failed: \(message)")
        }
    }
}
#endif
