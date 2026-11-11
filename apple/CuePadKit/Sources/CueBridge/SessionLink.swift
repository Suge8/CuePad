#if os(macOS)
import CueStore
import Foundation

/// 一个会话一条的（Pi、Claude Code）不看 `id`；一个接入承载多个会话的（Codex、OpenCode）由接入自己遵守、按 `id` 找会话。
/// 桥（`Bridge`）按会话找到它转交命令；这家或这个模型做不到的（`AgentCapabilities`）桥先拒绝，到不了这里。
@MainActor
public protocol SessionLink: AnyObject {
    /// 以这句话开新一轮：会话歇着就直接开始，在跑（含压缩、等你确认）就先打断这一轮。受理即返回，不等模型做完；
    /// 托管的 Claude Code 先报收下再拒收，等它开始回话或明确拒收才返回（`ClaudeDelivery`）。
    /// 以这家的提示词模板或技能开头的由它展开（Pi 的桥扩展、Codex 的 `skill:`），投送请求 id 随展开后的那条消息进会话。
    func send(_ message: SessionMessage, in id: Session.ID) async throws
    /// 斜杠命令：不开轮的照原样执行，返回即这家执行了它；会开一轮的（带话的模式切换、OpenCode 的模板）与 `send` 同一规则。
    /// `deliveryID` 是投送请求 id，收得下的（托管的 Claude Code）随命令交出、据它认这条命令的结果。
    func command(_ line: String, deliveryID: String?, in id: Session.ID) async throws
    /// 请会话退出：这一刻下桥，在跑的这一轮先停下再收进程（CuePad 起的进程见 `HostedProcesses`；Pi、OpenCode 由扩展、服务自己先停这一轮）。
    /// 受理即返回，下线经 `Bridge.detach` 报告。
    func end(_ id: Session.ID) async throws
    func abort(_ id: Session.ID) async throws
    /// 核对真实投送身份和停止必须在接收端的同一同步段；不支持的接入明确拒绝，不能降级为无条件停止。
    func abort(_ id: Session.ID, deliveryID: String, turnStartedAt: Int64) async throws
    /// 对话里不多一句话。受理即返回，不等模型。
    func retry(_ id: Session.ID) async throws
    func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws
    /// 至少给一项；会话名已去掉首尾空白、不是空的（桥先检查过）。
    func configure(_ config: SessionConfig, in id: Session.ID) async throws
    func canNameItself(_ id: Session.ID) -> Bool
    /// 按第一句话（`firstMessage`）起一个短名，返回整理好的名字（`SessionNameSuggestion.cleaned`）；不写回，写不写由 App 复核后走改名。
    func suggestName(from firstMessage: String, in id: Session.ID) async throws -> String
}

/// 这家没实现的操作缺省拒绝。
extension SessionLink {
    public func send(_ message: SessionMessage, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func command(_ line: String, deliveryID: String?, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func end(_ id: Session.ID) async throws { throw BridgeError.unsupported }
    public func abort(_ id: Session.ID) async throws { throw BridgeError.unsupported }
    public func abort(_ id: Session.ID, deliveryID: String, turnStartedAt: Int64) async throws { throw BridgeError.rejected("unsupported_stop_turn") }
    public func retry(_ id: Session.ID) async throws { throw BridgeError.unsupported }
    public func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func configure(_ config: SessionConfig, in id: Session.ID) async throws { throw BridgeError.unsupported }
    public func canNameItself(_ id: Session.ID) -> Bool { false }
    public func suggestName(from firstMessage: String, in id: Session.ID) async throws -> String { throw BridgeError.unsupported }
}
#endif
