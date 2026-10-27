#if os(macOS)
import CueStore
import Foundation

/// 托管会话的控制：发话与斜杠命令都是先停下在跑的这一轮、再以它开新一轮；斜杠命令就是 `/` 开头的一句话（ACP 的约定），
/// 只认 Agent 报过的命令名。权限确认的允许回 allow_once，拒绝回 reject_once。结束是关标准输入、等它收尾。
extension ACPSession: SessionLink {
    func send(_ message: PiMessage, in _: PiSession.ID) async throws {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty else {
            throw PiBridgeError.rejected("empty")
        }
        try await interrupt()
        try prompt(ACPContent.prompt(text: message.text, images: message.images), deliveryID: message.deliveryID)
        if !message.text.isEmpty, let id {
            bridge?.update(id) { if $0.firstMessage == nil { $0.firstMessage = String(message.text.prefix(PiSessionName.firstMessageLimit)) } }
        }
    }

    func command(_ line: String, in _: PiSession.ID) async throws {
        guard line.hasPrefix("/") else { throw PiBridgeError.rejected("bad_request") }
        let name = line.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard commands.contains(name) else { throw PiBridgeError.rejected("unknown_command") }
        try await interrupt()
        try prompt(ACPContent.prompt(text: line, images: []))
    }

    func abort(_: PiSession.ID) async throws {
        try await interrupt()
    }

    func answer(_ answer: PiAnswerValue, to promptID: String, in _: PiSession.ID) async throws {
        guard let pending = permission else { throw PiBridgeError.rejected("no_prompt") }
        guard facts.question?.promptID == promptID else { throw PiBridgeError.rejected("stale_prompt") }
        guard case .confirmed(let allowed) = answer else { throw PiBridgeError.rejected("bad_answer") }
        let kinds = allowed ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        guard let option = kinds.lazy.compactMap({ kind in pending.options.first { $0["kind"]?.string == kind }?["optionId"] }).first else {
            throw PiBridgeError.rejected("bad_answer")
        }
        permission = nil
        facts.questions = []
        try live.respond(to: pending.request, result: ["outcome": ["outcome": "selected", "optionId": option]])
        publish()
    }

    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in _: PiSession.ID) async throws {
        do {
            try await configure(model: model?.id, effort: thinking)
        } catch ACPError.server(ACPError.invalidParams, _) where model != nil {
            throw PiBridgeError.unknownModel(agent)
        }
        guard let name else { return }
        guard let sessionID, let cwd, try await dialect.rename(name, session: sessionID, cwd: cwd, on: live) else { throw PiBridgeError.unsupported }
        if let id { bridge?.update(id) { $0.name = name } }
    }

    /// 关标准输入请它收尾退出，不走再结束它（`ChildProcess.stop`）；下线随进程退出报告。
    func end(_: PiSession.ID) async throws {
        let process = try live.process
        Task { await process.stop() }
    }
}
#endif
