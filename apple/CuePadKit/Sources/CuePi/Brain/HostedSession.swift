#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// Cue 的大脑：CuePad 起的一个 Agent 运行时子进程（用户已登录哪家用哪家）。
/// Cue 不写代码：系统提示整份由 CuePad 给，原生工具只有读文件类，外加 CuePad 的 MCP 服务；对话由 CuePad 自己记，
/// 运行时不留会话（各家用自己不落盘的方式；OpenCode 落进它的库、用完删掉，见各实现的头注释），也不改用户的配置文件，只用参数、环境变量与临时文件。
public struct CueBrainConfig: Sendable {
    public let runtime: AgentKind
    public let executable: URL
    /// 运行时自己的模型写法（Pi 是 `提供方/模型`）；nil 用运行时的默认
    public let model: String?
    /// 思考强度：各家共用 Pi 的档位，各实现映射到自己的写法、夹到模型支持的档位
    public let effort: PiThinkingLevel?
    public let fast: Bool
    /// 整份替换运行时内置的系统提示
    public let systemPrompt: String
    public let workingDirectory: URL
    /// CuePad 的 MCP 服务（stdio）的命令行：`[<cuepad 绝对路径>, "mcp"]`
    public let mcp: [String]
    /// 加给运行时与 MCP 服务的环境变量（在 CuePad 自己的环境之上）
    public let environment: [String: String]

    public init(
        runtime: AgentKind, executable: URL, model: String?, effort: PiThinkingLevel?, fast: Bool = false, systemPrompt: String,
        workingDirectory: URL, mcp: [String], environment: [String: String]
    ) {
        self.runtime = runtime
        self.executable = executable
        self.model = model
        self.effort = effort
        self.fast = fast
        self.systemPrompt = systemPrompt
        self.workingDirectory = workingDirectory
        self.mcp = mcp
        self.environment = environment
    }
}

/// 各家同形的事件。一轮：`turnStarted` →（`speaking`、`context`、`tool` / `toolDone`…）→ `failed`（出错时）→ `turnFinished`；
/// 一轮进行中再 `send` 的话并进这一轮，不另起一轮。
/// 子代理与嵌套的工具调用、子代理说的话不报。
public enum TurnEvent: Sendable, Equatable {
    case turnStarted
    /// 正在说的话（`PiDraft`，规则同它）：这一轮此刻正在说的这条回答到目前为止的全文，随增量报（不节流），nil 是清掉。
    /// 转成工具调用、这一轮出错（都在 `turnFinished` 之前）、下一轮开始时清掉；正常说完的留着——
    /// `turnFinished` 时还留着的就是这一轮的回答，没有就是这一轮没说话。各家都在协议层得出（逐字增量累积，每段说完时换成运行时给的定稿，不发增量也有），回答不另取一份
    case speaking(PiDraft?)
    /// 上下文用量，各家同一口径：`used` 是最近一次模型请求的输入 token 合计（含缓存的读与写，不含输出）；`window` 是在用模型的上下文窗口，
    /// 运行时没报时为 nil。托管会话在桥上显示的（`PiSession.context`）也是这一份
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
    case exited(ShownText?)
}

/// Cue 的大脑看到的会话：CuePad 起、掌握全部输入输出的一个 Agent 进程（`AgentFacts.brain` 开出各家的那一种，`CueBrainConfig.startBrain` 起好）。
/// Claude Code、Codex、ACP 的大脑与它们的托管会话共用一套一轮的判定（`ClaudeHostedSession`、`CodexDriver`、`ACPSession`；Codex 的大脑是 `CodexBrain`）；
/// Pi 的托管会话要撑过 App 重启、走桥扩展，只有大脑走 Pi 的 RPC（`PiBrain`）；OpenCode 的托管会话连用户的后台服务，
/// 大脑另起一台隔离的服务（`OpenCodeBrain`），一轮的解读与接入同用 `OpenCodeTurn`。
@MainActor
public protocol HostedSession: AnyObject {
    /// 只有一个订阅者：CuePad 里管 Cue 的那一处
    var events: AsyncStream<TurnEvent> { get }
    /// 起进程并做完握手；之后就能 `send`。起不来时已起的进程停掉再抛
    func start(_ config: CueBrainConfig) async throws
    /// 模型能看图（起好之后才算数）；看不了时别交图，交了各家也只是丢掉或报错
    var seesImages: Bool { get }
    /// 说一句话（可带图，按各家原生的图片输入交）：空闲时开始一轮，正忙时插进当前这一轮
    func send(_ text: String, images: [PiImage]) async throws
    /// 开新会话：清掉此前的对话，系统提示、工具、模型与强度不变，下一句从空白的对话说起。只在空闲时调
    func newSession() async throws
    /// 就地换模型（运行时自己的写法，同 `CueBrainConfig.model`）与思考强度：进程与上下文不动，下一次请求模型起生效（`seesImages` 随新模型）。
    /// nil 的那项不动：运行时的默认取不回来，回到默认要换大脑。运行时不认（没有这个模型、没登录这家提供方……）时抛，在用的不变
    func configure(model: String?, effort: PiThinkingLevel?) async throws
    /// 结束进程：返回的等待在进程（连同它起的子进程）退出后结束，不需要主线程（App 退出时在主线程之外等）；随后发 `exited(nil)`
    func stop() -> @concurrent @Sendable () async -> Void
}

public enum HostedSessionError: Error, Equatable {
    /// 还没启动、已经停了或进程已退出
    case notRunning
    case rejected(String)
}

extension HostedSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notRunning: String(localized: "Cue 没在运行")
        case .rejected(let message): String(localized: "Cue 的运行时拒绝了请求：\(message)")
        }
    }
}

extension CueBrainConfig {
    /// 运行时的环境：CuePad 自己的环境加上配置给的与 `extra`，PATH 按 `ExecutableLocator.environment` 的规则（配置给的 PATH 已是找到它的那组目录）。
    func launchEnvironment(adding extra: [String: String] = [:]) -> [String: String] {
        ExecutableLocator(searchDirectories: []).environment(launching: executable, overrides: environment.merging(extra) { $1 })
    }

    @MainActor public func startBrain() async throws -> any HostedSession {
        let brain = runtime.facts.brain()
        try await brain.start(self)
        return brain
    }
}
#endif
