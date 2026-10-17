import CueStore
import Foundation

/// Cue 的工具经 MCP 提供（`cuepad mcp`）：stdio，一行一个 JSON-RPC 消息。只做握手版：initialize、notifications/initialized、ping、
/// tools/list、tools/call；不做 resources、prompts、sampling、tasks。请求按到达顺序一个个处理。
public struct CueMCPServer: Sendable {
  let tools: CueTools

  /// 接受的协议版本：回客户端请求的那个；别的版本回最新的，由客户端决定是否继续（MCP 的版本协商）。
  static let protocolVersions = ["2025-11-25", "2025-06-18"]
  /// 大脑登记这个服务用的名字。三家运行时给模型的工具名都是 `mcp__<名字>__<工具>`（`toolPrefix`），系统提示照这个写：
  /// 只写 task 时模型多半先按 task 调，被运行时以"没有这个工具"拒掉，偶尔就此认定工具调不起来。
  public static let name = "cuepad"
  public static let toolPrefix = "mcp__\(name)__"

  public init(store: CueStore) { tools = CueTools(store: store) }

  /// 读到 `input` 结束为止，每条回应交给 `output`（一行，不含换行）。
  public func serve(_ input: some AsyncSequence<String, any Error>, output: (String) -> Void) async throws {
    for try await line in input where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      if let reply = await handle(line) { output(reply) }
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
      return Self.result(id: id, ["tools": CueTools.definitions])
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
