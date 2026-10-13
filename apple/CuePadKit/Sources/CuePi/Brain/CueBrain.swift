#if os(macOS)
import CueStore
import Foundation

/// Cue 的大脑：CuePad 起的一个 Agent 运行时子进程（`CueRuntime`：Pi、Codex 或 Claude Code，用户已登录哪家用哪家）。
/// Cue 不写代码：系统提示整份由 CuePad 给，原生工具只有读文件类，外加 CuePad 的 MCP 服务；对话由 CuePad 自己记，
/// 运行时不落会话（三家各用自己不落盘的方式，见各实现的头注释），也不改用户的配置文件，只用参数、环境变量与临时文件。
public struct CueBrainConfig: Sendable {
    public var runtime: CueRuntime
    /// 运行时的可执行文件（`pi`、`codex`、`claude`）
    public var executable: URL
    /// 运行时自己的模型写法（Pi 是 `提供方/模型`）；nil 用运行时的默认
    public var model: String?
    /// 思考强度：三家共用 Pi 的档位，各实现映射到自己的写法、夹到模型支持的档位
    public var effort: PiThinkingLevel?
    /// 整份替换运行时内置的系统提示
    public var systemPrompt: String
    public var workingDirectory: URL
    /// CuePad 的 MCP 服务（stdio）的命令行：`[<cuepad 绝对路径>, "mcp"]`
    public var mcp: [String]
    /// 加给运行时与 MCP 服务的环境变量（在 CuePad 自己的环境之上）
    public var environment: [String: String]

    public init(
        runtime: CueRuntime, executable: URL, model: String? = nil, effort: PiThinkingLevel? = nil, systemPrompt: String,
        workingDirectory: URL, mcp: [String], environment: [String: String] = [:]
    ) {
        self.runtime = runtime
        self.executable = executable
        self.model = model
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.workingDirectory = workingDirectory
        self.mcp = mcp
        self.environment = environment
    }
}

/// 三家同形的事件。一轮：`turnStarted` →（`context`…）→ `reply`（有文字时）/ `failed`（出错时）→ `turnFinished`；
/// 一轮进行中再 `send` 的话并进这一轮，不另起一轮。被 `abort` 停下的一轮照常以 `turnFinished` 结束，不报 `reply` 也不报 `failed`。
public enum CueBrainEvent: Sendable, Equatable {
    case turnStarted
    /// 这一轮最后的助手文字
    case reply(String)
    /// 最近一次模型请求的输入 token 合计（含缓存命中与写入）与上下文窗口
    case context(used: Int, window: Int?)
    case turnFinished
    /// 这一轮出错（提供方报错、额度、认证……），原文
    case failed(String)
    /// 进程退出，之后不再有事件。`stop()` 让它退出的为 nil，否则是退出原因（退出码与标准错误的末尾）
    case exited(String?)
}

public protocol CueBrain: AnyObject, Sendable {
    /// 只有一个订阅者：CuePad 里管 Cue 的那一处
    var events: AsyncStream<CueBrainEvent> { get }
    /// 起进程并做完握手；之后就能 `send`
    func start(_ config: CueBrainConfig) async throws
    /// 说一句话：空闲时开始一轮，正忙时插进当前这一轮
    func send(_ text: String) async throws
    /// 停下当前这一轮（空闲时什么都不做），进程留着、能接着说
    func abort() async throws
    /// 结束进程并等它（连同它起的子进程）退出；返回时 `exited(nil)` 已发出
    func stop() async
}

public enum CueBrainError: Error, Equatable {
    /// 还没启动、已经停了或进程已退出
    case notRunning
    /// 运行时拒绝了请求（原文）
    case rejected(String)
    /// 启动期间进程退出（原因同 `CueBrainEvent.exited`）
    case exited(String)
}

extension CueBrainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRunning: "Cue 没在运行"
        case .rejected(let message): "Cue 的运行时拒绝了请求：\(message)"
        case .exited(let reason): "Cue 的运行时退出了：\(reason)"
        }
    }
}

extension CueBrainConfig {
    /// 按 `runtime` 起对应的大脑。
    public func startBrain() async throws -> any CueBrain {
        let brain: any CueBrain = switch runtime {
        case .pi: PiBrain()
        case .codex: CodexBrain()
        case .claude: ClaudeBrain()
        }
        try await brain.start(self)
        return brain
    }
}
#endif
