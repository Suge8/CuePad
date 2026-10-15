#if os(macOS)
import CueStore
import Foundation

/// 一个在线会话的控制通道：Pi 经扩展的 socket，其他 Agent 经各自的适配（钩子与收件箱、控制接口、托管进程、后台服务）。
/// 桥（`PiBridge`）按会话找到它转交命令；这个 Agent 的这类会话做不到的（`AgentCapabilities`）桥先拒绝，到不了这里。
@MainActor
public protocol SessionLink: AnyObject {
    /// 发消息；返回受理时的投递方式（受理只表示已收下）。
    func send(_ message: PiMessage) async throws -> PiDelivery
    func command(_ line: String, whenBusy: PiQueueMode?) async throws
    /// 请会话退出：托管的进程退出（不论这一轮在不在跑），终端里的像在终端里退出那样收尾。受理即返回，下线随后经 `PiBridge.detach` 报告。
    func end() async throws
    func abort() async throws
    func answer(_ answer: PiAnswerValue, to promptID: String) async throws
    /// 至少给一项；会话名已去掉首尾空白、不是空的（桥先检查过）。
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws
}
#endif
