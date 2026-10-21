#if os(macOS)
import CueStore
import Darwin
import Foundation
import Observation

extension PiBridge {
    /// 发消息（文字 + 图片），以这句开新一轮：会话歇着就直接开始，在跑就先打断这一轮；打断不了的（`AgentCapabilities.speakBlocked`）
    /// 拒收、带上原因，不排队。受理即返回，不代表模型成功。
    public func send(_ message: PiMessage, to id: PiSession.ID) async throws {
        let link = try control(id, needs: message.images.isEmpty ? [] : .images)
        if let session = session(id: id), let why = session.capabilities.speakBlocked(in: session.state, agent: session.agent) {
            throw PiBridgeError.rejected("failed: \(why)")
        }
        try await link.send(message, in: id)
    }

    /// 执行一条斜杠命令（整行，以 / 开头）：Pi 的内置命令由扩展调 Pi 的接口做，扩展命令、提示词模板与 skill 由 Pi 派发；会开一轮的
    /// （模板与 skill 展开成这一轮的提示词）与 `send` 同一规则，在跑就先打断。受理只表示已收下，命令自己的输出只出现在 Agent 的界面里；
    /// 清单里没有的命令抛 `rejected("unknown_command")`，必填参数没给抛 `rejected("missing_argument")`。
    public func command(_ line: String, in id: PiSession.ID) async throws {
        try await control(id, needs: .commands).command(line, in: id)
    }

    /// 让该会话从会话文件重新载入到最新（同一会话的另一个进程刚写过文件后）；扩展判断能否安全重载，不能就提示用户。只有 Pi 有。
    public func reload(_ id: PiSession.ID) async throws {
        try await pi(id).reload()
    }

    /// 结束该会话并等它下线；`AgentTimeouts.end` 内没下线抛 `notEnded`。
    public func end(_ id: PiSession.ID) async throws {
        let link = try control(id, needs: .end)
        let changes = changes()  // 先订阅再动手：下线的那一刻不会漏
        try await link.end(id)
        try await withDeadline(AgentTimeouts.end, orThrow: PiBridgeError.notEnded) {
            for await change in changes {
                if case .ended(let ended, _) = change, ended.id == id { return }
            }
            throw CancellationError()
        }
    }

    /// 停止该会话正在跑的这一轮（相当于在 Agent 里按 Esc）：受理即返回，会话随后歇下（`.settled`），能接着说。
    /// 已经空闲时什么也不发生（也成功）；只停它自己这一轮，它派出的子代理照常跑。
    public func abort(_ id: PiSession.ID) async throws {
        try await control(id, needs: .abort).abort(id)
    }

    /// 回答该会话正在等的弹窗；`promptID` 不是正在等的那个、或答案对不上时抛 `PiBridgeError.rejected`。
    public func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws {
        try await control(id, needs: .answer).answer(answer, to: promptID, in: id)
    }

    /// 换该会话的模型、思考强度或会话名（至少给一项，会话名不能是空白）：先换模型再设强度，强度按新模型支持的范围夹取。
    /// 模型不在 Agent 的模型表里抛 `unknownModel`，提供方没配好密钥抛 `rejected("no_auth")`；成功后会话的上报（`model`、`thinking`）随 `infoChanged` 更新。
    public func configure(model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, name: String? = nil, in id: PiSession.ID) async throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model != nil || thinking != nil || name != nil, name?.isEmpty != true else { throw PiBridgeError.rejected("bad_request") }
        var needs: AgentCapabilities = model != nil || thinking != nil ? .model : []
        if name != nil { needs.insert(.rename) }
        try await control(id, needs: needs).configure(model: model, thinking: thinking, name: name, in: id)
    }

    /// 请该会话查一次所有 OAuth 订阅的额度：查到的随 `changes()` 的 `.quota` 报出（与回复里带回的同一条路），
    /// 再返回；有一家没查到抛 `rejected("failed: …")`（查到的那几家照常报出）。只有 Pi 有。
    public func refreshQuota(in id: PiSession.ID) async throws {
        try await pi(id).refreshQuota()
    }

    /// 会话的控制通道；这个 Agent 的这类会话做不到（`AgentCapabilities`）就抛 `unsupported`：能做什么只看能力表，通道不判断。
    private func control(_ id: PiSession.ID, needs: AgentCapabilities) throws -> any SessionLink {
        guard let link = controls[id], let session = session(id: id) else { throw PiBridgeError.unknownSession(id) }
        guard session.capabilities.isSuperset(of: needs) else { throw PiBridgeError.unsupported }
        return link
    }

    private func pi(_ id: PiSession.ID) throws -> Link {
        guard let link = controls[id] else { throw PiBridgeError.unknownSession(id) }
        guard let pi = link as? Link else { throw PiBridgeError.unsupported }
        return pi
    }
}
#endif
