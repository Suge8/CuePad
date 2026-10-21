#if os(macOS)
import CueStore
import CueText
import Foundation

extension ClaudeHostedSession {
    func send(_ message: PiMessage, in _: PiSession.ID) async throws {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty else {
            throw PiBridgeError.rejected("empty")
        }
        try await say(ClaudeStream.content(text: message.text, images: message.images), uuid: message.deliveryID ?? UUID().uuidString)
        // 托管进程自己的钩子不登记（见类注释），首条消息由这里记，与终端会话的 UserPromptSubmit 同一规则
        if !message.text.isEmpty, let id {
            bridge?.update(id) { if $0.firstMessage == nil { $0.firstMessage = String(message.text.prefix(PiSessionName.firstMessageLimit)) } }
        }
    }

    /// 斜杠命令就是以 / 开头的一句话：托管进程会执行它（内置命令、skill、自定义命令）。
    func command(_ line: String, in _: PiSession.ID) async throws {
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let name = line.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard commands.contains(name) else { throw PiBridgeError.rejected("unknown_command") }
        try await say(.string(line), uuid: UUID().uuidString)
    }

    /// 发出的话（斜杠命令也是）一定开始一轮：从发出那一刻算，不等它的 `system/init`（中间隔着钩子）；为它停下的那一轮收尾时已经开了。
    func began() {
        if !facts.running { starting = [] }
        beginTurn()
        publish(at: .now)
    }

    /// 这一轮开跑了（或没跑就结束了）：放行等着它的停止。
    func started() {
        starting?.forEach { $0.resume() }
        starting = nil
    }

    func abort(_: PiSession.ID) async throws {
        try await stop(restarting: false)
    }

    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in _: PiSession.ID) async throws {
        guard let id else { throw PiBridgeError.sessionEnded }
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
        try stream.write(["type": "control_response", "response": ["subtype": "success", "request_id": .string(waiting.request), "response": decision]])
        facts.questions = []
        publish(at: .now)
    }

    /// 关标准输入：它收完手上的就退出（在等确认时也立即退出）。
    func end(_: PiSession.ID) async throws { stream.closeInput() }
}
#endif
