#if os(macOS)
import CueStore
import Foundation

/// 一家 ACP Agent 与标准不同的地方：ACP 驱动（`ACPSession`）的扩展点，每家一个实现。标准里有的一律走标准（一轮、正在说的话、工具、
/// 权限确认、模型与强度的配置项、斜杠命令、`usage_update`），这里只放标准没有的；没写的取下面扩展里的标准做法。
/// 各家的扩展方法与通知（方法名以 `_` 开头，如 Grok 的 `_x.ai/*`）只在这里认，翻成驱动的动作（`ACPSignal`）与要你回答的一问（`ACPAsk`）。
protocol ACPDialect: Sendable {
    var agent: AgentKind { get }
    /// 起它的 ACP 服务的参数（接在可执行文件后面）
    var arguments: [String] { get }
    /// 当 Cue 的大脑时怎么配：加给运行时的环境、`session/new` 的 `_meta`（整份替换系统提示、工具白名单这些标准没有的），
    /// 可以把文件写进本次运行的临时目录 `directory`
    func brain(_ config: CueBrainConfig, directory: URL) throws -> ACPBrainSetup
    /// 会话开好后 MCP 服务才连（标准里 `session/new` 回来时已连上）：大脑等它报 `ACPSignal.mcp` 再说第一句话
    var connectsMCPLater: Bool { get }
    /// 正忙时把这句并进在跑的这一轮：做不到（标准没有这个动作）返回 false，驱动等这一轮做完再以它开新一轮
    @MainActor func steer(_ text: String, images: [PiImage], session: String, on connection: ACPConnection) async throws -> Bool
    /// 改会话名：做不到返回 false
    @MainActor func rename(_ name: String, session: String, cwd: URL, on connection: ACPConnection) async throws -> Bool
    /// `session/prompt` 的 `_meta`：带上 CuePad 的投送请求 id，好在会话记录里认回（`deliveryID` 为 nil 是 CuePad 自己起的话）
    func promptMeta(deliveryID: String?) -> JSONValue?
    /// 一条通知（含标准通知里各家自己的种类）对驱动意味着什么
    func signals(_ method: String, _ params: JSONValue) -> [ACPSignal]
    /// 工具调用的名字，模型看到的写法（标准只有给人看的标题 `title`）
    func toolName(_ call: JSONValue) -> String
    /// 工具结果的文字（标准在 `content` 里）
    func toolResult(_ update: JSONValue) -> String
    /// 模型的上下文窗口（标准没有）；`session` 是 `session/new`、`session/load` 的结果
    func window(of model: String, in session: JSONValue) -> Int?
    /// 能交图（`agent` 是握手的回应）
    func acceptsImages(_ agent: JSONValue) -> Bool
    /// Agent 发来的这个请求是它自己的提问（标准只有权限确认，那一种驱动自己认）：翻成要你回答的一问；不是提问为 nil
    func ask(_ method: String, _ params: JSONValue) -> ACPAsk?
}

/// 大脑的配法（`ACPDialect.brain`）
struct ACPBrainSetup {
    var environment: [String: String]
    var meta: JSONValue?
}

/// 各家通知翻成的驱动动作
enum ACPSignal: Equatable {
    /// Agent 自己开了一轮（不是 CuePad 的 `session/prompt` 开的）；已在跑时不算
    case turnStarted
    /// 这一轮结束（`failure` 是出错的原文）
    case turnFinished(failure: String?)
    /// 最近一次请求模型的输入合计（口径同 `TurnEvent.context`）
    case context(used: Int)
    /// CuePad 的 MCP 服务连上了，或连不上（`failure` 是原因）
    case mcp(failure: String?)
}

extension ACPDialect {
    var connectsMCPLater: Bool { false }

    @MainActor func steer(_ text: String, images: [PiImage], session: String, on connection: ACPConnection) async throws -> Bool { false }

    @MainActor func rename(_ name: String, session: String, cwd: URL, on connection: ACPConnection) async throws -> Bool { false }

    func promptMeta(deliveryID: String?) -> JSONValue? { nil }

    func signals(_ method: String, _ params: JSONValue) -> [ACPSignal] { [] }

    func toolName(_ call: JSONValue) -> String { call["title"]?.string ?? "?" }

    func toolResult(_ update: JSONValue) -> String { ACPContent.text(update["content"]) }

    func window(of model: String, in session: JSONValue) -> Int? { nil }

    func acceptsImages(_ agent: JSONValue) -> Bool { agent["agentCapabilities"]?["promptCapabilities"]?["image"]?.bool == true }

    func ask(_ method: String, _ params: JSONValue) -> ACPAsk? { nil }
}

/// ACP 的内容块。
enum ACPContent {
    /// 一句话的内容：文字在前（空文字不带）、图片以 base64 在后。
    static func prompt(text: String, images: [PiImage]) -> [JSONValue] {
        let text: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        return text + images.map { ["type": "image", "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())] }
    }

    /// 内容里的文字：一个文字块，或工具结果的内容列表（`{type: content, content: 文字块}` 与直接的文字块）拼起来。
    static func text(_ content: JSONValue?) -> String {
        if let text = content?["text"]?.string { return text }
        return (content?.array ?? []).compactMap { $0["content"]?["text"]?.string ?? $0["text"]?.string }.joined(separator: "\n")
    }
}
#endif
