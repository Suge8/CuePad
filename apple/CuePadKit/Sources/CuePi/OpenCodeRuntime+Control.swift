#if os(macOS)
import CueStore
import Foundation

extension OpenCodeRuntime {
    private func live(_ id: PiSession.ID) throws -> (Connection, Tracked, String) {
        guard let connection, connection.ready, let sessionID = bridge.session(id: id)?.sessionID, let tracked = sessions[sessionID], tracked.online else {
            throw PiBridgeError.sessionEnded
        }
        return (connection, tracked, sessionID)
    }

    /// 以这句开新一轮：先 `interrupt`（歇着时是空操作），再按缺省的 `steer` 收进收件箱。`interrupt` 受理即回、清掉这一轮已记下的唤醒，
    /// 之后收进来的话在被停下的这一轮收尾时开出新一轮（服务的 `SessionRunCoordinator`），所以不会并进被停下的这一轮。
    /// 原生的 `interrupt?resume=true` 是"先收话再打断"：两次请求之间这一轮到了步骤边界就会把话读进将被停下的这一轮，不用。
    public func send(_ message: PiMessage, in id: PiSession.ID) async throws {
        let (connection, _, sessionID) = try live(id)
        struct File: Encodable { var uri: String }
        struct Metadata: Encodable { var cuepadDelivery: String }
        struct Prompt: Encodable { var text: String; var files: [File]; var metadata: Metadata? }
        try await interrupt(sessionID, connection)
        let prompt = Prompt(
            text: message.text, files: message.images.map { File(uri: "data:\($0.mimeType);base64,\($0.data.base64EncodedString())") },
            metadata: message.deliveryID.map(Metadata.init))
        try await connection.client.call("POST", "/api/session/\(sessionID)/prompt", body: prompt)
    }

    /// `/compact` 不开轮，照它的缺省（下一个步骤边界压缩）；其余命令展开成这一轮的提示词，与 `send` 同一规则。
    public func command(_ line: String, in id: PiSession.ID) async throws {
        let (connection, tracked, sessionID) = try live(id)
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts.first.map(String.init) ?? ""
        let arguments = parts.count > 1 ? String(parts[1]) : ""
        if name == Self.compact {
            struct Compact: Encodable {}
            try await connection.client.call("POST", "/api/session/\(sessionID)/compact", body: Compact())
            return
        }
        guard try await catalog(tracked.directory, connection.client).commands.contains(where: { $0.name == name }) else {
            throw PiBridgeError.rejected("unknown_command")
        }
        struct Command: Encodable { var name: String; var text: String }
        try await interrupt(sessionID, connection)
        do {
            try await connection.client.call("POST", "/api/session/\(sessionID)/command", body: Command(name: name, text: arguments))
        } catch let error as OpenCodeAPIError {
            throw PiBridgeError.rejected(error.tag == "CommandNotFoundError" ? "unknown_command" : "failed: \(error.message)")
        }
    }

    public func abort(_ id: PiSession.ID) async throws {
        let (connection, _, sessionID) = try live(id)
        try await interrupt(sessionID, connection)
    }

    /// 停下在跑的这一轮（含压缩）。在不在跑由服务判断（歇着时是空操作），不看事件流推出的忙闲。
    private func interrupt(_ sessionID: String, _ connection: Connection) async throws {
        try await connection.client.call("POST", "/api/session/\(sessionID)/interrupt")
    }

    public func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws {
        let (connection, tracked, _) = try live(id)
        guard let question = tracked.facts.questions.first(where: { $0.promptID == promptID }), let target = Self.parse(promptID) else {
            throw PiBridgeError.rejected("stale_prompt")
        }
        if target.kind == .permission {
            let decision: String
            switch answer {
            case .option(Self.allowOnce), .confirmed(true): decision = "once"
            case .option(Self.allowAlways): decision = "always"
            case .option(Self.reject), .confirmed(false): decision = "reject"
            default: throw PiBridgeError.rejected("bad_answer")
            }
            struct Reply: Encodable { var decision: String }
            try await connection.client.call(
                "POST", "/api/session/\(target.sessionID)/permission/\(target.id)/reply", body: Reply(decision: decision))
            return
        }
        let forms = try await connection.client.get(OpenCodeData<[OpenCodeForm]>.self, "/api/session/\(target.sessionID)/form").data
        guard let field = forms.first(where: { $0.id == target.id })?.fields.first else { throw PiBridgeError.rejected("stale_prompt") }
        let value: OpenCodeAnswer
        switch (question.kind.known, answer) {
        case (.select, .option(let label)):
            guard let option = field.options?.first(where: { $0.label == label }) else { throw PiBridgeError.rejected("bad_answer") }
            value = .string(option.value)
        case (_, .text(let text)) where question.acceptsText: value = .string(text)
        case (.confirm, .confirmed(let yes)): value = .bool(yes)
        default: throw PiBridgeError.rejected("bad_answer")
        }
        struct Reply: Encodable { var answer: [String: OpenCodeAnswer] }
        try await connection.client.call("POST", "/api/session/\(target.sessionID)/form/\(target.id)/reply", body: Reply(answer: [field.key: value]))
    }

    public func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
        let (connection, tracked, sessionID) = try live(id)
        if let name {
            struct Update: Encodable { var title: String }
            try await connection.client.call("PATCH", "/api/session/\(sessionID)", body: Update(title: name))
        }
        if model != nil || thinking != nil {
            let current = tracked.info.model
            guard let key = model ?? current.map({ PiModelKey(provider: $0.providerID, id: $0.id) }) else { throw PiBridgeError.unknownModel(.opencode) }
            // 服务刚起时头一次取到的模型表是空的（实测 2.0.25：约 0.2 秒后才有），开会话紧接着配模型就会撞上：没找到先重取一次再说
            var target = try await catalog(tracked.directory, connection.client).models.first { $0.key == key }
            if target == nil { target = try await catalog(tracked.directory, connection.client, reload: true).models.first { $0.key == key } }
            guard let target else { throw PiBridgeError.unknownModel(.opencode) }
            let variants = (target.variants ?? []).map(\.id)
            // 模型没有强度档（没有 variant）时不带；关闭就是不带 variant
            let level = thinking.flatMap { target.thinkingLevels.isEmpty ? nil : $0.clamped(to: target.thinkingLevels) }
            let variant: String? = if thinking != nil { level == .off ? nil : level?.rawValue }
                else { current?.variant.flatMap { variants.contains($0) ? $0 : nil } }
            let ref = OpenCodeModelRef(id: target.id, providerID: target.providerID, variant: variant)
            struct Switch: Encodable { var model: OpenCodeModelRef }
            try await connection.client.call("POST", "/api/session/\(sessionID)/model", body: Switch(model: ref))
        }
        // 桥上的名字与模型只随服务自己的事件（改名、选模型）更新，不在这里先写
    }

    /// 结束：停下在跑的一轮，会话下线（它还在服务里，再有活动——终端里接着说、CuePad 接着它——就重新上线）。
    public func end(_ id: PiSession.ID) async throws {
        let (connection, _, sessionID) = try live(id)
        try await interrupt(sessionID, connection)
        guard self.connection === connection, sessions[sessionID]?.online == true else { return }
        sessions[sessionID]?.online = false
        ended[sessionID] = Date()
        bridge.detach(bridgeID(sessionID, connection), reason: .closed(reason: "quit"))
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let connection = try await ensureService()
        struct Create: Encodable { var location: OpenCodeLocation }
        let data = try await connection.client.call(
            "POST", "/api/session", body: Create(location: OpenCodeLocation(directory: directory.path(percentEncoded: false))))
        let info = try JSONDecoder().decode(OpenCodeData<OpenCodeSessionInfo>.self, from: data).data
        let id = try await host(info, connection) {
            $0.hosted = true
            $0.launchToken = launchToken
        }
        let sessionID = info.id
        do {
            return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
        } catch {
            // 配不上时结束只让它下线，会话还在服务里：开会话失败的不留，从服务里删掉
            _ = try? await connection.client.call("DELETE", "/api/session/\(sessionID)")
            throw error
        }
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        let connection = try await ensureService()
        let online = sessions[session.id]?.online == true
        let info: OpenCodeSessionInfo
        do {
            info = try await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(session.id)").data
        } catch let error as OpenCodeAPIError where error.status == 404 {
            throw PiBridgeError.unknownSession(session.id)
        }
        return try await host(info, connection) { if !online { $0.hosted = true } }
    }

    /// 让 CuePad 托管的会话上线；已经在线的（比如终端里正开着）不算托管。
    func host(_ info: OpenCodeSessionInfo, _ connection: Connection, _ body: (inout Tracked) -> Void) async throws -> PiSession.ID {
        guard self.connection === connection else { throw PiBridgeError.sessionEnded }
        var tracked = sessions[info.id] ?? Tracked(info: info)
        tracked.online = true
        ended[info.id] = nil
        body(&tracked)
        sessions[info.id] = tracked
        listed?.insert(info.id)
        try await catalog(info.location.directory, connection.client)
        publish(info.id)
        return bridgeID(info.id, connection)
    }

    /// 连着的服务；没开就把它拉起来，等连上、拉完快照。
    func ensureService() async throws -> Connection {
        if connection == nil {
            try await launchService()
            refresh()
        }
        // 起服务期间登记文件的变化可能已经让它连上、拉完快照
        if let connection, connection.ready { return connection }
        let id = UUID()
        let timeout = Task { [weak self] in
            guard (try? await Task.sleep(for: AgentTimeouts.launch)) != nil else { return }
            self?.waiters.removeValue(forKey: id)?.resume(throwing: AgentRuntimeError.launchTimedOut(.opencode))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { waiters[id] = $0 }
    }

    /// `opencode service start`：起后台服务、写好登记文件才返回（实测约 0.2 秒）。服务自成一个会话（不在这条命令的进程组里，
    /// 超时结束整组碰不到它），标准输入输出指到 /dev/null（不握着这边的管道）：实测 2.0.25。
    private func launchService() async throws {
        guard let executable = await opencode() else { throw AgentRuntimeError.notInstalled(.opencode) }
        let locator = await locate()
        // 服务常驻，它起的工具也用这个 PATH
        let environment = locator.environment(launching: executable, overrides: paths.environment)
        guard let result = await ChildProcess.run(executable, ["service", "start"], environment: environment, timeout: AgentTimeouts.launch, collect: false)
        else { throw AgentRuntimeError.launchTimedOut(.opencode) }
        guard result.status == 0 else { throw AgentRuntimeError.launchFailed(.opencode, String(localized: "opencode service start 退出码 \(result.status)")) }
        startedService = (executable, environment)
    }
}
#endif
