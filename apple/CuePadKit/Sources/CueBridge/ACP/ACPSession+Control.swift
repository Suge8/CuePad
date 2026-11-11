#if os(macOS)
import CueStore
import Foundation

/// 斜杠命令就是 `/` 开头的一句话（ACP 的约定），只认 Agent 报过的命令名。
extension ACPSession: SessionLink {
    func send(_ message: SessionMessage, in _: Session.ID) async throws {
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.images.isEmpty else {
            throw BridgeError.rejected("empty")
        }
        try await interrupt()
        try prompt(ACPContent.prompt(text: message.text, images: message.images), deliveryID: message.deliveryID)
        if !message.text.isEmpty, let id {
            bridge?.update(id) { if $0.firstMessage == nil { $0.firstMessage = String(message.text.prefix(SessionName.firstMessageLimit)) } }
        }
    }

    func command(_ line: String, deliveryID _: String?, in id: Session.ID) async throws {
        guard line.hasPrefix("/") else { throw BridgeError.rejected("bad_request") }
        let name = line.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard bridge?.session(id: id)?.commands.contains(where: { $0.name == name }) == true else { throw BridgeError.rejected("unknown_command") }
        try await interrupt()
        try prompt(ACPContent.prompt(text: line, images: []))
    }

    func abort(_: Session.ID) async throws {
        stopPhase.cancelAll()
        try await interrupt(cancellable: false)
    }

    func answer(_ answer: AnswerValue, to promptID: String, in _: Session.ID) async throws {
        guard let pending else { throw BridgeError.rejected("no_prompt") }
        guard facts.question?.promptID == promptID else { throw BridgeError.rejected("stale_prompt") }
        switch pending.ask.answer(answer) {
        case nil:
            throw BridgeError.rejected("bad_answer")
        case .next(let ask):
            present(ask, request: pending.request)
        case .result(let result):
            self.pending = nil
            facts.questions = []
            try live.respond(to: pending.request, result: result)
            publish()
        }
    }

    func configure(_ config: SessionConfig, in _: Session.ID) async throws {
        guard config.fast == nil else { throw BridgeError.unsupported }
        let model = config.model, thinking = config.thinking, name = config.name
        do {
            try await configure(model: model.map(agent.modelRef), effort: thinking)
        } catch ACPError.server(ACPError.invalidParams, _) where model != nil {
            throw BridgeError.unknownModel(agent)
        }
        guard let name else { return }
        guard let sessionID, let cwd, try await dialect.rename(name, session: sessionID, cwd: cwd, on: live) else { throw BridgeError.unsupported }
        if let id { bridge?.update(id) { $0.name = name } }
    }

    func end(_ id: Session.ID) async throws {
        _ = try live
        processes?.retire(id, link: self)
    }
}
#endif
