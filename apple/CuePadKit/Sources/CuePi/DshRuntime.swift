#if os(macOS)
import CueStore
import Foundation

/// dsh（DeepSeek Harness，`@deepseek-ai/dsh`）的接入：会话只有 CuePad 托管的，托管会话与 Cue 的大脑都走通用 ACP 驱动起
/// `dsh --profile acp`（`DshLaunch`），ACP 标准里没有的经随包插件的扩展方法补上（`dsh-cuepad.mjs` 头注释）。
///
/// - 会话放哪：用户自己的 DSH_HOME（登录、`acp` profile 里的设置与缺省模型照用），存储根却是 CuePad 在它下面的 `cuepad/sessions`，明文。
///   dsh 的存储是内部格式——按代际迁移、默认每批追加一个 zstd 帧、一个根只认一种编码（混进别的编码它整根拒读），同一根里的明文与压缩
///   不能并存。CuePad 跟读、补写对话要逐行读，所以托管会话进自己的明文根，代价是它们不出现在 dsh 的 web、桌面版的历史里；
///   在 CuePad 的历史里照常接着说。
/// - 不跟读用户在 web、桌面版里的会话：zstd 要另加解压依赖，旧会话还停在 v0–v3 各代的格式（每代各一份解码），读出来也只能看不能控
///   （那些会话的进程不是 CuePad 起的，没有通道）。为只读的历史不值。
/// - 托管的进程是 CuePad 起的（歇满 `PiBridge.hostedIdle` 由桥请它退出），撑不过 App 退出。
/// - 能力全有（`AgentCapabilities.of`）：发图按开会话时的模型定——dsh-acp 握手时判定收不收图，之后换到能看图的模型也一样。
///
/// 待接：托管会话与大脑由通用 ACP 驱动（feat/agent-grok）承载，落地后这里实现 `AgentRuntime`、`DshBrain` 换成驱动开的会话。
@MainActor
public final class DshRuntime {}

/// Cue 的大脑用 dsh：接上通用 ACP 驱动之前起不来。
@MainActor
final class DshBrain: HostedSession {
    let events = AsyncStream<TurnEvent> { $0.finish() }
    var seesImages: Bool { false }
    func start(_ config: CueBrainConfig) async throws { throw AgentRuntimeError.launchFailed(.dsh, "等通用 ACP 驱动接上") }
    func send(_ text: String, images: [PiImage]) async throws { throw HostedSessionError.notRunning }
    func newSession() async throws { throw HostedSessionError.notRunning }
    func configure(model: String?, effort: PiThinkingLevel?) async throws { throw HostedSessionError.notRunning }
    func abort() async throws { throw HostedSessionError.notRunning }
    func stop() -> @concurrent @Sendable () async -> Void { {} }
}
#endif
