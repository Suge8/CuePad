#if os(macOS)
import CueStore
import CueText
import Foundation

extension ClaudeHostedSession {
    /// 托管会话起进程：权限确认经标准输入问 CuePad，模式 auto（见类注释）。
    func host(executable: URL, arguments: [String], directory: URL, environment: [String: String]) async throws -> ChildProcess {
        let process = try await launch(
            executable, ["--permission-prompt-tool", "stdio", "--permission-mode", "auto"] + arguments, directory: directory, environment: environment)
        stream?.onReply = { [deliveries] in deliveries.replying() }
        return process
    }

    func send(_ message: PiMessage, in _: PiSession.ID) async throws {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty else {
            throw PiBridgeError.rejected("empty")
        }
        try await deliver(hosted(ClaudeStream.content(text: message.text, images: message.images), uuid: message.deliveryID))
        // 托管进程自己的钩子不登记（见类注释），首条消息由这里记，与终端会话的 UserPromptSubmit 同一规则
        if !message.text.isEmpty, let id {
            bridge?.update(id) { if $0.firstMessage == nil { $0.firstMessage = String(message.text.prefix(PiSessionName.firstMessageLimit)) } }
        }
    }

    /// 斜杠命令就是以 / 开头的一句话：托管进程会执行它（内置命令、skill、自定义命令）。
    func command(_ line: String, deliveryID: String?, in _: PiSession.ID) async throws {
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let name = line.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard commands.contains(name) else { throw PiBridgeError.rejected("unknown_command") }
        try await deliver(hosted(.string(line), uuid: deliveryID))
    }

    /// 先停下在跑的这一轮，再交出、等它定下送没送达（`ClaudeDelivery`）。
    private func deliver(_ message: JSONValue) async throws {
        try await interrupt(restarting: true)
        try await deliveries.deliver(message["uuid"]?.string ?? "") { try put(message) }
    }

    /// 托管会话发的话：带上 `uuid`（投送请求的 id 落进会话文件），写明 `next`——不写时缺省可能是 `later`，
    /// 要等后台的工作做完才读（实测等到被停下时挪去后台的命令跑完）。
    private func hosted(_ content: JSONValue, uuid: String? = nil) -> JSONValue {
        Self.userMessage(content, extra: ["session_id": "", "uuid": .string(uuid ?? UUID().uuidString), "priority": "next"])
    }

    func abort(_: PiSession.ID) async throws {
        try await interrupt(restarting: false)
    }

    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in _: PiSession.ID) async throws {
        guard let id else { throw PiBridgeError.sessionEnded }
        let stream = try live
        if let model {
            // Claude Code 换模型时先向服务端核对：只有"不支持这个模型"才是模型表里没有，别的（网络、限流、认证、余额）照原话报。
            // 兼容网关不认的模型常只回 400/404 而没有上面的短语（DeepSeek 400："…but you passed <id>"；官方 404："model: <id>"），
            // 但 400 也可能是别的原因（官方余额不足："Your credit balance is too low…"），所以 400/404 还要原文里点了这次的模型 id 才算
            do {
                try await stream.setModel(model.id)
            } catch PiBridgeError.rejected(let reason) {
                let text = reason.lowercased()
                let unknown = ["unsupported model", "not found", "unknown model", "invalid model"].contains { text.contains($0) }
                    || (["api error: 400", "api error: 404"].contains { text.contains($0) } && text.contains(model.id.lowercased()))
                throw unknown ? PiBridgeError.unknownModel(.claudeCode) : PiBridgeError.rejected("failed: \(reason)")
            }
            bridge?.update(id) { session in session.model = session.availableModels.first { $0.key == model } ?? ClaudeCode.model(model.id) }
        }
        if let thinking {
            let effort = try await stream.setEffort(thinking)
            bridge?.update(id) { $0.thinking = Open(rawValue: effort) }
        }
        if let name {
            _ = try await stream.request(["subtype": "rename_session", "title": .string(name)])
            bridge?.update(id) { $0.name = name }
        }
    }

    func answer(_ answer: PiAnswerValue, to promptID: String, in _: PiSession.ID) async throws {
        guard let waiting = permission else { throw PiBridgeError.rejected("no_prompt") }
        let decision = try waiting.permission.decision(answer, to: promptID)
        permission = nil
        try live.write(["type": "control_response", "response": ["subtype": "success", "request_id": .string(waiting.request), "response": decision]])
        facts.questions = []
        publish(at: .now)
    }

    /// 关标准输入：它收完手上的就退出（在等确认时也立即退出）。
    func end(_: PiSession.ID) async throws { try live.closeInput() }
}
#endif
