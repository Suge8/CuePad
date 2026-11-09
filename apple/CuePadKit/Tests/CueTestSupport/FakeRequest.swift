#if os(macOS)
import Foundation

/// 假模型收到的一个请求，三种协议读成同一个样子（`messages` 按对话先后）。
public struct FakeRequest: Sendable {
  public enum API: Sendable { case chat, responses, messages, other }
  public enum Role: Sendable { case system, user, assistant, tool }

  public struct Message: Sendable {
    public let role: Role
    public let text: String
    /// `<mime>:<base64 长度>`
    public let images: [String]
    /// 助手这一条里调的工具名
    public let calls: [String]
  }

  public let api: API
  public let method: String
  public let path: String
  public let model: String
  public let system: String
  public let messages: [Message]
  /// 请求带的工具清单（名字）
  public let tools: [String]
  /// 思考强度（Chat 的 `reasoning_effort`、Responses 的 `reasoning.effort`）
  public let effort: String?
  public let body: Data

  /// 最近一条你的话（工具结果不算）
  public var prompt: String { lastUser.map { messages[$0].text } ?? "" }
  public var images: [String] { lastUser.map { messages[$0].images } ?? [] }
  /// 最近一条你的话之后，助手已调过几次工具
  public var step: Int { after.filter { !$0.calls.isEmpty }.count }
  /// 最近一条你的话之后的工具结果
  public var results: [String] { after.filter { $0.role == .tool }.map(\.text) }
  /// 你说过的每一句
  public var said: [String] { messages.filter { $0.role == .user }.map(\.text) }
  var estimatedTokens: Int { messages.reduce(0) { $0 + $1.text.count } / 4 + 1 }
  public var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }

  private var lastUser: Int? { messages.lastIndex { $0.role == .user } }
  private var after: ArraySlice<Message> { messages[((lastUser ?? -1) + 1)...] }

  init(path: String, method: String, body: Data) {
    self.path = path
    self.method = method
    self.body = body
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let route = path.split(separator: "?").first.map(String.init) ?? path
    api = method != "POST" ? .other
      : route.hasSuffix("/chat/completions") ? .chat
      : route.hasSuffix("/responses") ? .responses
      : route.hasSuffix("/messages") || route.hasSuffix("/messages/count_tokens") ? .messages
      : .other
    model = json["model"] as? String ?? ""
    let parsed: (system: String, messages: [Message]) = switch api {
    case .chat: Self.chat(json)
    case .responses: Self.responses(json)
    case .messages: Self.anthropic(json)
    case .other: ("", [])
    }
    (system, messages) = parsed
    tools = (json["tools"] as? [[String: Any]] ?? []).compactMap { tool in
      (tool["function"] as? [String: Any])?["name"] as? String ?? tool["name"] as? String
    }
    effort = json["reasoning_effort"] as? String ?? (json["reasoning"] as? [String: Any])?["effort"] as? String
  }

  /// 工具清单里叫这个名字的、或以 `_<名字>` 结尾的那个（MCP 工具带着服务名前缀）
  func tool(_ name: String) -> String {
    tools.first { $0 == name } ?? tools.first { $0.hasSuffix("_" + name) } ?? name
  }

  // MARK: 三种协议

  private static func chat(_ json: [String: Any]) -> (String, [Message]) {
    var system: [String] = []
    var messages: [Message] = []
    for message in json["messages"] as? [[String: Any]] ?? [] {
      let content = message["content"]
      let parts = content as? [[String: Any]] ?? []
      let text = (content as? String) ?? parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
      let images = parts.compactMap { ($0["image_url"] as? [String: Any])?["url"] as? String }.map(dataURL)
      let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
      switch message["role"] as? String {
      case "system", "developer": system.append(text)
      case "user": messages.append(Message(role: .user, text: text, images: images, calls: []))
      case "assistant": messages.append(Message(role: .assistant, text: text, images: [], calls: calls))
      case "tool": messages.append(Message(role: .tool, text: text, images: images, calls: []))
      default: break
      }
    }
    return (system.joined(separator: "\n"), messages)
  }

  private static func responses(_ json: [String: Any]) -> (String, [Message]) {
    var system = [json["instructions"] as? String].compactMap(\.self)
    var messages: [Message] = []
    for item in json["input"] as? [[String: Any]] ?? [] {
      switch item["type"] as? String ?? "message" {
      case "message":
        let content = item["content"]
        let parts = content as? [[String: Any]] ?? []
        let text = (content as? String) ?? parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let images = parts.compactMap { $0["type"] as? String == "input_image" ? $0["image_url"] as? String : nil }.map(dataURL)
        switch item["role"] as? String {
        case "system", "developer": system.append(text)
        case "user": messages.append(Message(role: .user, text: text, images: images, calls: []))
        default: messages.append(Message(role: .assistant, text: text, images: [], calls: []))
        }
      case "function_call", "custom_tool_call", "local_shell_call":
        messages.append(Message(role: .assistant, text: "", images: [], calls: [item["name"] as? String ?? "shell"]))
      case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
        let output = item["output"]
        let text = (output as? String) ?? (output as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        messages.append(Message(role: .tool, text: text, images: [], calls: []))
      default: break
      }
    }
    return (system.joined(separator: "\n"), messages)
  }

  /// 带工具结果的你那一条算工具结果（Claude Code 把提醒的文字也放在那一条里）
  private static func anthropic(_ json: [String: Any]) -> (String, [Message]) {
    let system = (json["system"] as? String) ?? (json["system"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    var messages: [Message] = []
    for message in json["messages"] as? [[String: Any]] ?? [] {
      let content = message["content"]
      let blocks = content as? [[String: Any]] ?? []
      func texts(_ blocks: [[String: Any]]) -> String {
        blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
      }
      func images(_ blocks: [[String: Any]]) -> [String] {
        blocks.compactMap { block in
          guard block["type"] as? String == "image", let source = block["source"] as? [String: Any] else { return nil }
          return "\(source["media_type"] as? String ?? "?"):\((source["data"] as? String)?.count ?? 0)"
        }
      }
      let text = (content as? String) ?? texts(blocks)
      if message["role"] as? String == "assistant" {
        let calls = blocks.compactMap { $0["type"] as? String == "tool_use" ? $0["name"] as? String : nil }
        messages.append(Message(role: .assistant, text: text, images: [], calls: calls))
        continue
      }
      let results = blocks.filter { $0["type"] as? String == "tool_result" }
      guard !results.isEmpty else {
        messages.append(Message(role: .user, text: text, images: images(blocks), calls: []))
        continue
      }
      for result in results {
        let inner = result["content"]
        let text = (inner as? String) ?? texts(inner as? [[String: Any]] ?? [])
        messages.append(Message(role: .tool, text: text, images: images(inner as? [[String: Any]] ?? []), calls: []))
      }
      // dsh 把进行中插进来的话放在工具结果后面的文字块里：算你的话（Claude Code 放在那里的提醒是 <system-reminder> 开头的，不算）
      let interjection = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.filter { !$0.hasPrefix("<system-reminder>") }
      if !interjection.isEmpty { messages.append(Message(role: .user, text: interjection.joined(separator: "\n"), images: [], calls: [])) }
    }
    return (system, messages)
  }

  private static func dataURL(_ url: String) -> String {
    guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return "url:\(url.count)" }
    let mime = url.dropFirst("data:".count).prefix { $0 != ";" && $0 != "," }
    return "\(mime):\(url[url.index(after: comma)...].count)"
  }
}
#endif
