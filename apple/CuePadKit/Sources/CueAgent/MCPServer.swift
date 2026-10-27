import CueStore
import Foundation

/// Cue 的工具经 MCP 提供（`cuepad mcp`；后台整理记忆的大脑用 `cuepad mcp --dream`，只有 merge）：stdio，一行一个 JSON-RPC 消息。只做握手版：initialize、notifications/initialized、ping、
/// tools/list、tools/call；不做 resources、prompts、sampling、tasks。请求按到达顺序一个个处理。
public struct CueMCPServer: Sendable {
  let tools: CueTools

  /// 接受的协议版本：回客户端请求的那个；别的版本回最新的，由客户端决定是否继续（MCP 的版本协商）。
  static let protocolVersions = ["2025-11-25", "2025-06-18"]
  /// 大脑登记这个服务用的名字。
  public static let name = "cuepad"
  /// 模型在这家看到的 CuePad 工具名的前缀，唯一的一处（系统提示照它写工具名，大脑的事件照它去掉）：
  /// Pi 是原名（随包的扩展 cue-tools.ts 照原名登记，不走 Pi 内置 MCP 的 `mcp__` 命名）；Codex 也是原名（MCP 工具放在命名空间
  /// `mcp__<服务>__` 里，函数名是原名）；Claude Code 一律是 `mcp__<服务>__<工具>`，改不了；OpenCode 是 `<服务>_<工具>`，Grok Build 是 `<服务>__<工具>`。
  public static func toolPrefix(on runtime: AgentKind) -> String {
    switch runtime {
    case .pi, .codex: ""
    case .claudeCode: "mcp__\(name)__"
    case .opencode: "\(name)_"
    case .grok: "\(name)__"
    }
  }

  /// 这家不把 MCP 工具的说明与参数交给模型，要写进系统提示（`CuePrompt.toolManual`）：Grok Build 的模型请求里只有一个按关键词搜 MCP 工具的
  /// `search_tool` 与转调的 `use_tool`（源码 sampler_turn.rs、tool_list.rs），大脑关掉了这两样，模型照名字直接调的 MCP 工具照常执行。
  public static func promptsTools(on runtime: AgentKind) -> Bool { runtime == .grok }

  /// 模型在这家看到的工具名。
  public static func toolName(_ tool: String, on runtime: AgentKind) -> String { toolPrefix(on: runtime) + tool }

  /// 大脑事件里的工具名（`TurnEvent.tool`）：去掉 CuePad 的前缀并小写（Claude Code 的 `Read`）。
  public static func bareName(_ name: String, on runtime: AgentKind) -> String {
    let prefix = toolPrefix(on: runtime)
    return (!prefix.isEmpty && name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name).lowercased()
  }

  public init(store: CueStore, wait: TimeInterval, toolset: CueTools.Toolset = .cue) { tools = CueTools(store: store, wait: wait, toolset: toolset) }

  /// 读到 `input` 结束为止，每条回应交给 `output`（一行，不含换行）；`output` 抛错（对端已关）就结束。
  public func serve(_ input: some AsyncSequence<String, any Error>, output: (String) throws -> Void) async throws {
    for try await line in input where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      if let reply = await handle(line) { try output(reply) }
    }
  }

  /// 处理一行；通知（没有 id）与不需要回应的返回 nil。
  private func handle(_ line: String) async -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
      return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "不是 JSON"]])
    }
    guard let message = object as? [String: Any] else { return Self.error(id: NSNull(), code: -32600, "不支持批量") }
    guard let method = message["method"] as? String else {
      // 客户端回给我们的响应不处理（我们不发请求）
      let isResponse = message["result"] != nil || message["error"] != nil
      return isResponse ? nil : Self.error(id: message["id"] ?? NSNull(), code: -32600, "不是 JSON-RPC 请求")
    }
    guard let id = message["id"] else { return nil }
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
      let requested = params["protocolVersion"] as? String
      return Self.result(
        id: id,
        [
          "protocolVersion": requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0],
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": Self.name, "title": "CuePad", "version": "1"],
        ])
    case "ping":
      return Self.result(id: id, [:])
    case "tools/list":
      return Self.result(id: id, ["tools": CueTools.definitions(tools.toolset)])
    case "tools/call":
      guard let name = params["name"] as? String else { return Self.error(id: id, code: -32602, "缺少工具名") }
      guard let result = await tools.call(name, params["arguments"] as? [String: Any] ?? [:]) else {
        return Self.error(id: id, code: -32602, "没有工具 \(name)")
      }
      return Self.result(
        id: id,
        ["content": [["type": "text", "text": result.text]], "isError": result.isError])
    default:
      return Self.error(id: id, code: -32601, "不支持 \(method)")
    }
  }

  private static func result(id: Any, _ result: [String: Any]) -> String { encode(["jsonrpc": "2.0", "id": id, "result": result]) }

  private static func error(id: Any, code: Int, _ message: String) -> String {
    encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
  }

  private static func encode(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}
