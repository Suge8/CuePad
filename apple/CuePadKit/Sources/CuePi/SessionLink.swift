#if os(macOS)
import CueStore
import Foundation

/// 一个在线会话的控制通道：Pi 经扩展的 socket，其他 Agent 经各自的适配（钩子与收件箱、控制接口、托管进程、后台服务）。
/// 桥（`PiBridge`）按会话找到它转交命令。做不到的（见 `AgentCapabilities`，界面不露出）由缺省实现抛 `PiBridgeError.unsupported`。
@MainActor
public protocol SessionLink: AnyObject {
    /// 发消息；返回受理时的投递方式（受理只表示已收下）。
    func send(_ message: PiMessage) async throws -> PiDelivery
    func command(_ line: String, whenBusy: PiQueueMode?) async throws
    func reload() async throws
    /// 请会话正常退出：受理即返回，下线随后经 `PiBridge.detach` 报告。
    func end() async throws
    func abort() async throws
    func answer(_ answer: PiAnswerValue, to promptID: String) async throws
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws
    /// 查一次订阅额度（结果经桥的 `.quota` 报出）。
    func refreshQuota() async throws
}

extension SessionLink {
    public func command(_ line: String, whenBusy: PiQueueMode?) async throws { throw PiBridgeError.unsupported }
    public func reload() async throws { throw PiBridgeError.unsupported }
    public func end() async throws { throw PiBridgeError.unsupported }
    public func abort() async throws { throw PiBridgeError.unsupported }
    public func answer(_ answer: PiAnswerValue, to promptID: String) async throws { throw PiBridgeError.unsupported }
    public func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws { throw PiBridgeError.unsupported }
    public func refreshQuota() async throws { throw PiBridgeError.unsupported }
}
#endif
