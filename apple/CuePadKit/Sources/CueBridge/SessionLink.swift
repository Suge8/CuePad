#if os(macOS)
import CueStore
import Foundation

@MainActor
public protocol SessionLink: AnyObject {
    /// 以这句话开新一轮：会话歇着就直接开始，在跑（含压缩、等你确认）就先打断这一轮。受理即返回，不等模型做完；
    /// 托管的 Claude Code 先报收下再拒收，等它开始回话或明确拒收才返回（`ClaudeDelivery`）。
    /// 以这家的提示词模板或技能开头的由它展开（Pi 的桥扩展、Codex 的 `skill:`），投送请求 id 随展开后的那条消息进会话。
    func send(_ message: SessionMessage, in id: Session.ID) async throws
    func command(_ line: String, opener: TurnOpener?, in id: Session.ID) async throws
    func end(_ id: Session.ID) async throws
    func abort(_ id: Session.ID) async throws
    func retry(_ id: Session.ID) async throws
    func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws
    func configure(_ config: SessionConfig, in id: Session.ID) async throws
    func canNameItself(_ id: Session.ID) -> Bool
    func suggestName(from firstMessage: String, in id: Session.ID) async throws -> String
    func refreshQuota(in id: Session.ID) async throws
}

extension SessionLink {
    public func send(_ message: SessionMessage, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func command(_ line: String, opener: TurnOpener?, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func end(_ id: Session.ID) async throws { throw BridgeError.unsupported }
    public func abort(_ id: Session.ID) async throws { throw BridgeError.unsupported }
    public func retry(_ id: Session.ID) async throws { throw BridgeError.unsupported }
    public func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func configure(_ config: SessionConfig, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func canNameItself(_ id: Session.ID) -> Bool { false }
    public func suggestName(from firstMessage: String, in id: Session.ID) async throws -> String { throw BridgeError.unsupported }
    public func refreshQuota(in id: Session.ID) async throws { throw BridgeError.unsupported }
}
#endif
