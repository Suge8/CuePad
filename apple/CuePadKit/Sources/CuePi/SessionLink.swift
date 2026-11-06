#if os(macOS)
import CueStore
import Foundation

/// 在线会话的控制通道：Pi 经扩展的 socket，其他 Agent 经各自的适配（钩子与收件箱、控制接口、托管进程、后台服务）。
/// 一个会话一条的（Pi、Claude Code）不看 `id`；一个接入承载多个会话的（Codex、OpenCode）由接入自己遵守、按 `id` 找会话。
/// 桥（`PiBridge`）按会话找到它转交命令；这个 Agent 的这类会话做不到的（`AgentCapabilities`）桥先拒绝，到不了这里。
@MainActor
public protocol SessionLink: AnyObject {
    /// 以这句话开新一轮：会话歇着就直接开始，在跑（含压缩、等你确认）就先打断这一轮。受理即返回，不等模型做完；
    /// 托管的 Claude Code 先报收下再拒收，等它开始回话或明确拒收才返回（`ClaudeDelivery`）。
    /// 以这家的提示词模板或技能开头的由它展开（Pi 的桥扩展、Codex 的 `skill:`），投送请求 id 随展开后的那条消息进会话。
    func send(_ message: PiMessage, in id: PiSession.ID) async throws
    /// 斜杠命令：不开轮的照原样执行，返回即这家执行了它；会开一轮的（带话的模式切换、OpenCode 的模板）与 `send` 同一规则。
    /// `deliveryID` 是投送请求 id，收得下的（托管的 Claude Code）随命令交出、据它认这条命令的结果。
    func command(_ line: String, deliveryID: String?, in id: PiSession.ID) async throws
    /// 请会话退出：托管的进程退出（不论这一轮在不在跑），终端里的像在终端里退出那样收尾。受理即返回，下线随后经 `PiBridge.detach` 报告。
    func end(_ id: PiSession.ID) async throws
    func abort(_ id: PiSession.ID) async throws
    /// 把出错的那一轮原样重跑一遍（`AgentCapabilities.retry`）：对话里不多一句话。受理即返回，不等模型。
    func retry(_ id: PiSession.ID) async throws
    func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws
    /// 至少给一项；会话名已去掉首尾空白、不是空的（桥先检查过）。
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws
    func configure(_ config: PiConfig, in id: PiSession.ID) async throws
    /// 这个会话能不能按第一句话给自己起名（`SessionNameSuggestion`）：Pi（桥扩展认 `title` 的）与 Codex 托管会话能；
    /// 自带会话名的几家（Claude Code、OpenCode、Grok、dsh）与终端里的 Codex 不起。
    func canNameItself(_ id: PiSession.ID) -> Bool
    /// 按第一句话（`firstMessage`）起一个短名，返回整理好的名字（`SessionNameSuggestion.cleaned`）；不写回，写不写由 App 复核后走改名。
    func suggestName(from firstMessage: String, in id: PiSession.ID) async throws -> String
}

/// 做不到的操作缺省拒绝（终端里只读的会话、没有斜杠命令或停止的终端会话）：桥按能力表先拒，实际到不了这里。
extension SessionLink {
    public func send(_ message: PiMessage, in id: PiSession.ID) async throws { throw PiBridgeError.unsupported }
    public func command(_ line: String, deliveryID: String?, in id: PiSession.ID) async throws { throw PiBridgeError.unsupported }
    public func end(_ id: PiSession.ID) async throws { throw PiBridgeError.unsupported }
    public func abort(_ id: PiSession.ID) async throws { throw PiBridgeError.unsupported }
    public func retry(_ id: PiSession.ID) async throws { throw PiBridgeError.unsupported }
    public func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws { throw PiBridgeError.unsupported }
    public func configure(_ config: PiConfig, in id: PiSession.ID) async throws {
        guard config.fast == nil else { throw PiBridgeError.unsupported }
        try await configure(model: config.model, thinking: config.thinking, name: config.name, in: id)
    }
    public func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
        throw PiBridgeError.unsupported
    }
    public func canNameItself(_ id: PiSession.ID) -> Bool { false }
    public func suggestName(from firstMessage: String, in id: PiSession.ID) async throws -> String { throw PiBridgeError.unsupported }
}
#endif
