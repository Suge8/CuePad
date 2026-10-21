#if os(macOS)
import CueStore
import CueText
import Foundation
import OSLog

extension CodexRuntime {
    public func send(_ message: PiMessage, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        try await deliver(CodexRPC.input(text: message.text, images: message.images), clientID: CodexHistory.clientID(for: message.deliveryID), to: session)
    }

    /// 以这句开新一轮：在跑就先停下这一轮。`turn/interrupt` 等这一轮真的中止了才回（实测 0.162.1：回应与 `turn/completed` 的
    /// `interrupted` 同时到），所以紧接着的 `turn/start` 开的是新一轮——它碰上还在跑的一轮会变成插话（压缩那一轮则拒收）。
    /// 被停下的那一轮不报歇下（`restarting`）：这句开出新一轮就从此刻算起，没开成才歇下。
    func deliver(_ input: [JSONValue], clientID: String, to session: Tracked) async throws {
        session.restarting = .stopping
        defer { session.restarting = nil }
        do {
            try await interrupt(session)
            try await call(session, "turn/start", ["threadId": .string(session.threadID), "clientUserMessageId": .string(clientID), "input": .array(input)])
        } catch {
            if session.restarting == .stopped { session.facts.endTurn() }
            publish(session)
            throw error
        }
        guard session.restarting == .stopped else { return }
        startTurn(session, at: .now)
        publish(session)
    }

    public func command(_ line: String, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1)
        let name = parts.first.map(String.init) ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch name {
        case "compact":
            try await call(session, "thread/compact/start", ["threadId": .string(session.threadID)])
        case "name":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            try await configure(model: nil, thinking: nil, name: argument, in: id)
        case "model":
            guard !argument.isEmpty else { throw PiBridgeError.rejected("missing_argument") }
            try await configure(model: PiModelKey(provider: CodexModel.provider, id: argument), thinking: nil, name: nil, in: id)
        case "plan", "default":
            guard hosted[session.pid] != nil else { throw PiBridgeError.rejected("unknown_command") }
            try await collaborate(name == "plan" ? "plan" : "default", in: session)
            if !argument.isEmpty {
                try await deliver(CodexRPC.input(text: argument, images: []), clientID: CodexHistory.clientID(for: nil), to: session)
            }
        case _ where name.hasPrefix("skill:"):
            guard let skill = session.skills.first(where: { "skill:\($0.name)" == name }) else { throw PiBridgeError.rejected("unknown_command") }
            var input: [JSONValue] = [["type": "skill", "name": .string(skill.name), "path": .string(skill.path)]]
            input += CodexRPC.input(text: argument, images: [])
            try await deliver(input, clientID: CodexHistory.clientID(for: nil), to: session)
        default:
            throw PiBridgeError.rejected("unknown_command")
        }
    }

    /// 之后的轮次用的协作模式（实验接口）：模型与强度照会话此刻的，说明用这个模式内置的。
    private func collaborate(_ mode: String, in session: Tracked) async throws {
        let current = bridge.session(id: session.id)
        guard let model = current?.model?.key.id else { throw PiBridgeError.rejected("failed: 不知道这个会话用的模型") }
        var settings: [String: JSONValue] = ["model": .string(model), "developer_instructions": .null]
        if case .known(let level)? = current?.thinking { settings["reasoning_effort"] = .string(CodexModel.effort(level)) }
        try await call(session, "thread/settings/update", [
            "threadId": .string(session.threadID), "collaborationMode": ["mode": .string(mode), "settings": .object(settings)],
        ])
    }

    public func abort(_ id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        try await interrupt(session)
    }

    /// 停下 Codex 此刻在跑的那一轮（含压缩那一轮）；歇着什么都不做。在不在跑、是哪一轮只问 Codex（最近一轮），不另记这一轮的 id：
    /// 钩子推出的忙闲只给界面看，不拿来判断要不要停。
    private func interrupt(_ session: Tracked) async throws {
        let thread = JSONValue.string(session.threadID)
        do {
            let rpc = try await control(session)
            let latest = try await Self.lastTurn(session.threadID, on: rpc)
            guard latest?["status"]?.string == "inProgress", let turn = latest?["id"] else { return }
            try await rpc.call("turn/interrupt", ["threadId": thread, "turnId": turn])
        } catch CodexRPCError.server(-32600, _) {
            // 这一轮在问与停之间自己结束了（"no active turn to interrupt"）：要的就是它不在跑
        } catch CodexRPCError.server(_, let message) {
            throw PiBridgeError.rejected("failed: \(message)")
        }
    }

    /// 改名走 `thread/name/set`；模型与强度走 `thread/settings/update`，强度按新模型支持的范围夹取（`PiThinkingLevel.clamped`）。
    public func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
        guard let session = tracked[id] else { throw PiBridgeError.unknownSession(id) }
        if let name {
            try await call(session, "thread/name/set", ["threadId": .string(session.threadID), "name": .string(name)])
            bridge.update(id) { $0.name = name }
        }
        guard model != nil || thinking != nil else { return }
        let rpc = try await control(session)
        if models == nil { models = try await CodexModel.list(rpc) }
        let target = model?.id ?? bridge.session(id: id)?.model?.key.id
        let entry = models?.first { $0.id == target }
        if model != nil, entry == nil { throw PiBridgeError.unknownModel(.codex) }
        var settings: [String: JSONValue] = ["threadId": .string(session.threadID)]
        if let model { settings["model"] = .string(model.id) }
        if let thinking { settings["effort"] = .string(CodexModel.effort(thinking.clamped(to: entry?.efforts ?? []))) }
        try await call(session, "thread/settings/update", .object(settings))
        if let thread = try await rpc.call("thread/read", ["threadId": .string(session.threadID)])["thread"] {
            bridge.update(id) { self.apply(thread, to: &$0) }
        }
    }

    /// 托管的会话关掉进程（app-server 读到 EOF 收尾退出）；终端里的会话 Codex 没有让终端退出的接口（能力表里没有，桥先拒绝）。
    public func end(_ id: PiSession.ID) throws {
        guard let session = tracked[id], let rpc = hosted[session.pid] else { throw PiBridgeError.unsupported }
        rpc.close()
    }

    func call(_ session: Tracked, _ method: String, _ params: JSONValue) async throws {
        do {
            try await control(session).call(method, params)
        } catch CodexRPCError.server(_, let message) {
            throw PiBridgeError.rejected("failed: \(message)")
        }
    }
}
#endif
