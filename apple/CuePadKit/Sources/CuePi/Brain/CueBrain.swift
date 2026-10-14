#if os(macOS)
import CueStore
import Foundation

/// Cue 的大脑：CuePad 起的一个 Agent 运行时子进程（Pi、Codex 或 Claude Code，用户已登录哪家用哪家；OpenCode 不能当大脑）。
/// Cue 不写代码：系统提示整份由 CuePad 给，原生工具只有读文件类，外加 CuePad 的 MCP 服务；对话由 CuePad 自己记，
/// 运行时不落会话（三家各用自己不落盘的方式，见各实现的头注释），也不改用户的配置文件，只用参数、环境变量与临时文件。
public struct CueBrainConfig: Sendable {
    public var runtime: AgentKind
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
        runtime: AgentKind, executable: URL, model: String? = nil, effort: PiThinkingLevel? = nil, systemPrompt: String,
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

/// 三家同形的事件。一轮：`turnStarted` →（`speaking`、`context`、`tool` / `toolDone`…）→ `failed`（出错时）→ `turnFinished`；
/// 一轮进行中再 `send` 的话并进这一轮，不另起一轮。被 `abort` 停下的一轮照常以 `turnFinished` 结束，不报 `failed`。
/// 子代理与嵌套的工具调用、子代理说的话不报。
public enum CueBrainEvent: Sendable, Equatable {
    case turnStarted
    /// 正在说的话（`PiDraft`，规则同它）：这一轮此刻正在说的这条回答到目前为止的全文，随增量报（不节流），nil 是清掉。
    /// 转成工具调用、这一轮被停下或出错（都在 `turnFinished` 之前）、下一轮开始时清掉；正常说完的留着——
    /// `turnFinished` 时还留着的就是这一轮的回答，没有就是这一轮没说话。三家都在协议层得出（逐字增量累积，每段说完时换成运行时给的定稿，不发增量也有），回答不另取一份
    case speaking(PiDraft?)
    /// 最近一次模型请求的输入 token 合计（含缓存命中与写入）与上下文窗口
    case context(used: Int, window: Int?)
    /// 开始调一个工具：`id` 是运行时给这次调用的编号（做完时对上）；名字去掉 CuePad 的 MCP 前缀并小写（`task`、`read`；
    /// Codex 跑的命令记作 `bash`，参数是 `{"command": …}`），参数是 JSON 原文
    case tool(id: String, name: String, arguments: String)
    /// 这次调用做完了：结果里的文字（几段拼起来；命令是它的输出）与成败
    case toolDone(id: String, result: String, failed: Bool)
    case turnFinished
    /// 这一轮出错（提供方报错、额度、认证……），原文
    case failed(String)
    /// 进程退出，之后不再有事件。`stop()` 让它退出的为 nil，否则是退出原因（退出码与标准错误的末尾）
    case exited(String?)
}

@MainActor
public protocol CueBrain: AnyObject {
    /// 只有一个订阅者：CuePad 里管 Cue 的那一处
    var events: AsyncStream<CueBrainEvent> { get }
    /// 起进程并做完握手；之后就能 `send`。起不来时已起的进程停掉再抛
    func start(_ config: CueBrainConfig) async throws
    /// 模型能看图（起好之后才算数）；看不了时别交图，交了各家也只是丢掉或报错
    var seesImages: Bool { get }
    /// 说一句话（可带图，按各家原生的图片输入交）：空闲时开始一轮，正忙时插进当前这一轮
    func send(_ text: String, images: [PiImage]) async throws
    /// 停下当前这一轮（空闲时什么都不做），进程留着、能接着说
    func abort() async throws
    /// 结束进程：返回的等待在进程（连同它起的子进程）退出后结束，不需要主线程（App 退出时在主线程之外等）；随后发 `exited(nil)`
    func stop() -> @concurrent @Sendable () async -> Void
}

public enum CueBrainError: Error, Equatable {
    /// 还没启动、已经停了或进程已退出
    case notRunning
    /// 运行时拒绝了请求（原文）
    case rejected(String)
    /// 这家 Agent 不能当大脑
    case unsupported(AgentKind)
}

extension CueBrainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRunning: "Cue 没在运行"
        case .rejected(let message): "Cue 的运行时拒绝了请求：\(message)"
        case .unsupported(let kind): "\(kind.name) 不能当 Cue 的大脑"
        }
    }
}

/// 工具名去掉 CuePad 的 MCP 前缀（Pi 与 Claude Code 写成 `mcp__cuepad__task`）并小写（Claude Code 的 `Read`）。
func brainToolName(_ name: String) -> String {
    let prefix = "mcp__cuepad__"
    return (name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name).lowercased()
}

extension CueBrainConfig {
    /// 按 `runtime` 起对应的大脑。
    @MainActor public func startBrain() async throws -> any CueBrain {
        let brain: any CueBrain = switch runtime {
        case .pi: PiBrain()
        case .codex: CodexBrain()
        case .claudeCode: ClaudeBrain()
        case .opencode: throw CueBrainError.unsupported(runtime)
        }
        try await brain.start(self)
        return brain
    }
}
#endif
