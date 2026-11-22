#if os(macOS)
import CueStore
import Foundation

protocol ACPDialect: Sendable {
    var agent: AgentKind { get }
    var arguments: [String] { get }
    func brain(_ config: CueBrainConfig, directory: URL) throws -> ACPBrainSetup
    /// 会话开好后 MCP 服务才连（标准里 `session/new` 回来时已连上）：大脑等它报 `ACPSignal.mcp` 再说第一句话
    var connectsMCPLater: Bool { get }
    /// `session/prompt` 先进 Agent 自己的队列、跑起来时报 `ACPSignal.turnStarted`：报之前不插话（Grok 会把插话先跑成一轮，排到这句前面），等它报了再插
    var queuesPrompts: Bool { get }
    @MainActor func steer(_ text: String, images: [MessageImage], session: String, on connection: ACPConnection) async throws -> ACPSteer?
    @MainActor func rename(_ name: String, session: String, cwd: URL, on connection: ACPConnection) async throws -> Bool
    func promptMeta(deliveryID: String?) -> JSONValue?
    func signals(_ method: String, _ params: JSONValue) -> [ACPSignal]
    func tool(_ call: JSONValue) -> (name: String, input: JSONValue)
    func toolResult(_ update: JSONValue) -> String
    func window(of model: String, in session: JSONValue) -> Int?
    func acceptsImages(_ agent: JSONValue) -> Bool
    func ask(_ method: String, _ params: JSONValue) -> ACPAsk?
}

struct ACPBrainSetup {
    var environment: [String: String]
    var meta: JSONValue?
}

/// 并进在跑的这一轮的一句插话，这家怎么报它被哪一轮收下（`TurnEvent.received`）：`claim` 是它被收下时这家报的标识（`ACPSignal.claimed`）；
/// 不报的为 nil——这家只报插话搁浅、转成它自己开的一轮（`ACPSignal.stranded`），没搁浅的就是插进的那一轮收下的
struct ACPSteer {
    var claim: String?
}

enum ACPSignal {
    case turnStarted
    case turnFinished(failure: String?)
    case context(used: Int)
    case claimed(String)
    /// 插话来不及并进那一轮（它已不再请求模型），Agent 以它们（原话在 `text` 里）自己开了一轮
    case stranded(text: String)
    case mcp(failure: String?)
}

extension ACPDialect {
    var connectsMCPLater: Bool { false }
    var queuesPrompts: Bool { false }

    @MainActor func steer(_ text: String, images: [MessageImage], session: String, on connection: ACPConnection) async throws -> ACPSteer? { nil }

    @MainActor func rename(_ name: String, session: String, cwd: URL, on connection: ACPConnection) async throws -> Bool { false }

    func promptMeta(deliveryID: String?) -> JSONValue? { nil }

    func signals(_ method: String, _ params: JSONValue) -> [ACPSignal] { [] }

    func tool(_ call: JSONValue) -> (name: String, input: JSONValue) { (call["title"]?.string ?? "?", call["rawInput"] ?? [:]) }

    func toolResult(_ update: JSONValue) -> String { ACPContent.text(update["content"]) }

    func window(of model: String, in session: JSONValue) -> Int? { nil }

    func acceptsImages(_ agent: JSONValue) -> Bool { agent["agentCapabilities"]?["promptCapabilities"]?["image"]?.bool == true }

    func ask(_ method: String, _ params: JSONValue) -> ACPAsk? { nil }
}

enum ACPContent {
    static func prompt(text: String, images: [MessageImage]) -> [JSONValue] {
        let text: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        return text + images.map { ["type": "image", "mimeType": .string($0.mimeType), "data": .string($0.data.base64EncodedString())] }
    }

    static func text(_ content: JSONValue?) -> String {
        if let text = content?["text"]?.string { return text }
        return (content?.array ?? []).compactMap { $0["content"]?["text"]?.string ?? $0["text"]?.string }.joined(separator: "\n")
    }
}
#endif
