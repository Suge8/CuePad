#if os(macOS)
import Foundation
import Network

/// 读一个 HTTP/1.1 请求（`Content-Length` 或分块的正文）。
struct HTTPMessage {
  let method: String
  let path: String
  let body: Data

  static func read(from connection: NWConnection) async -> HTTPMessage? {
    var data = Data()
    while true {
      guard let chunk = await receive(connection) else { return nil }
      data.append(chunk)
      guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
      let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n")
      let start = lines.first?.split(separator: " ") ?? []
      guard start.count >= 2 else { return nil }
      let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
      }) { $1 }
      let rest = Data(data[end.upperBound...])
      let body: Data?
      if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
        body = dechunk(rest)
      } else {
        let length = headers["content-length"].flatMap(Int.init) ?? 0
        body = rest.count >= length ? rest.prefix(length) : nil
      }
      if let body { return HTTPMessage(method: String(start[0]), path: String(start[1]), body: body) }
    }
  }

  /// 收齐了（读到长度为 0 的那块）才有值
  private static func dechunk(_ data: Data) -> Data? {
    var body = Data(), at = data.startIndex
    while let line = data[at...].range(of: Data("\r\n".utf8)) {
      guard let size = Int(String(decoding: data[at..<line.lowerBound], as: UTF8.self).split(separator: ";")[0], radix: 16) else { return nil }
      if size == 0 { return body }
      let start = line.upperBound
      guard data.endIndex >= start + size + 2 else { return nil }
      body.append(data[start..<(start + size)])
      at = start + size + 2
    }
    return nil
  }

  /// 对方关了或出错为 nil
  static func receive(_ connection: NWConnection) async -> Data? {
    await withCheckedContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
        continuation.resume(returning: error != nil || (done && (data?.isEmpty ?? true)) ? nil : data ?? Data())
      }
    }
  }
}

struct Wire: Sendable {
  let connection: NWConnection

  @discardableResult
  func send(_ text: String) async -> Bool {
    await withCheckedContinuation { continuation in
      connection.send(content: Data(text.utf8), completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
    }
  }

  func json(status: Int, _ body: String) async {
    await send("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\ncontent-type: application/json\r\ncontent-length: \(body.utf8.count)\r\nconnection: close\r\n\r\n\(body)")
  }

  func events() async -> Bool {
    await send("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-cache\r\nconnection: close\r\n\r\n")
  }

  /// 等到 Agent 断开
  func disconnected() async {
    while await HTTPMessage.receive(connection) != nil {}
  }

  func close() { connection.cancel() }
}

func jsonText(_ object: Any) -> String {
  String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8), as: UTF8.self)
}

/// 一步答复按请求的协议写出去。
struct Encoder {
  let api: FakeRequest.API
  let request: FakeRequest
  let usage: Int
  let wire: Wire
  private let id = UUID().uuidString.prefix(8).lowercased()

  init(api: FakeRequest.API, request: FakeRequest, usage: Int, wire: Wire) {
    self.api = api
    self.request = request
    self.usage = usage
    self.wire = wire
  }

  private var streaming: Bool { request.json["stream"] as? Bool ?? (api == .responses) }

  func send(_ reply: FakeReply) async {
    switch reply {
    case .fail(let message, let status):
      let error: [String: Any] = api == .messages
        ? ["type": "error", "error": ["type": status == 429 ? "rate_limit_error" : "invalid_request_error", "message": message]]
        : ["error": ["message": message, "type": "invalid_request_error", "code": NSNull()]]
      await wire.json(status: status, jsonText(error))
    case .held(_, let next):
      await send(next)
    case .say, .call, .stream, .search, .custom:
      guard streaming else { return await wire.json(status: 200, jsonText(whole(reply))) }
      guard await wire.events() else { return }
      switch api {
      case .chat: await chat(reply)
      case .responses: await responses(reply)
      case .messages: await messages(reply)
      case .other: break
      }
    }
  }

  private func arguments(_ arguments: [String: any Sendable]) -> String { jsonText(arguments) }

  // MARK: Chat Completions

  private func chat(_ reply: FakeReply) async {
    func chunk(_ delta: [String: Any], finish: String? = nil) async -> Bool {
      var object: [String: Any] = ["id": "chatcmpl-\(id)", "object": "chat.completion.chunk", "created": 0, "model": request.model,
                                   "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { $0 as Any } ?? NSNull()]]]
      if finish != nil { object["usage"] = ["prompt_tokens": usage, "completion_tokens": 5, "total_tokens": usage + 5] }
      return await wire.send("data: \(jsonText(object))\n\n")
    }
    switch reply {
    case .say(let text):
      guard await chunk(["role": "assistant", "content": text]), await chunk([:], finish: "stop") else { return }
    case .call(let name, let input):
      let call: [String: Any] = ["index": 0, "id": "call_\(id)", "type": "function", "function": ["name": request.tool(name), "arguments": arguments(input)]]
      guard await chunk(["role": "assistant", "tool_calls": [call]]), await chunk([:], finish: "tool_calls") else { return }
    case .stream(let parts):
      for part in parts { guard await chunk(["role": "assistant", "content": part]) else { return } }
      return await wire.disconnected()
    default: return
    }
    await wire.send("data: [DONE]\n\n")
  }

  // MARK: Responses

  private func responses(_ reply: FakeReply) async {
    var sequence = 0
    func event(_ type: String, _ fields: [String: Any]) async -> Bool {
      var object = fields
      object["type"] = type
      object["sequence_number"] = sequence
      sequence += 1
      return await wire.send("event: \(type)\ndata: \(jsonText(object))\n\n")
    }
    let base: [String: Any] = ["id": "resp_\(id)", "object": "response", "created_at": 0, "model": request.model, "tools": [], "metadata": [:]]
    guard await event("response.created", ["response": base.merging(["status": "in_progress", "output": []]) { $1 }]) else { return }
    let item: [String: Any]
    switch reply {
    case .call(let name, let input):
      let json = arguments(input)
      let resolved = request.tool(name)
      item = ["type": "function_call", "id": "fc_\(id)", "call_id": "call_\(id)", "name": resolved, "arguments": json, "status": "completed"]
        .merging(request.found[resolved].map { ["namespace": $0] } ?? [:]) { $1 }
      guard await event("response.output_item.added", ["output_index": 0, "item": item.merging(["arguments": "", "status": "in_progress"]) { $1 }]),
            await event("response.function_call_arguments.delta", ["output_index": 0, "item_id": "fc_\(id)", "delta": json]),
            await event("response.function_call_arguments.done", ["output_index": 0, "item_id": "fc_\(id)", "arguments": json])
      else { return }
    case .say(let text):
      let message = "msg_\(id)"
      item = ["type": "message", "id": message, "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text, "annotations": []]]]
      guard await event("response.output_item.added", ["output_index": 0, "item": ["type": "message", "id": message, "role": "assistant", "status": "in_progress", "content": []]]),
            await event("response.content_part.added", ["output_index": 0, "item_id": message, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]]),
            await event("response.output_text.delta", ["output_index": 0, "item_id": message, "content_index": 0, "delta": text, "logprobs": []]),
            await event("response.output_text.done", ["output_index": 0, "item_id": message, "content_index": 0, "text": text, "logprobs": []]),
            await event("response.content_part.done", ["output_index": 0, "item_id": message, "content_index": 0, "part": ["type": "output_text", "text": text, "annotations": []]])
      else { return }
    case .custom(let name, let input):
      let resolved = request.tool(name)
      item = ["type": "custom_tool_call", "id": "ctc_\(id)", "call_id": "call_\(id)", "name": resolved, "input": input, "status": "completed"]
        .merging(request.found[resolved].map { ["namespace": $0] } ?? [:]) { $1 }
      guard await event("response.output_item.added", ["output_index": 0, "item": item.merging(["input": "", "status": "in_progress"]) { $1 }]),
            await event("response.custom_tool_call_input.delta", ["output_index": 0, "item_id": "ctc_\(id)", "delta": input]),
            await event("response.custom_tool_call_input.done", ["output_index": 0, "item_id": "ctc_\(id)", "input": input])
      else { return }
    case .search(let query):
      item = ["type": "tool_search_call", "id": "ts_\(id)", "call_id": "call_\(id)", "execution": "client", "arguments": ["query": query], "status": "completed"]
      guard await event("response.output_item.added", ["output_index": 0, "item": item.merging(["status": "in_progress"]) { $1 }]) else { return }
    case .stream(let parts):
      let message = "msg_\(id)"
      guard await event("response.output_item.added", ["output_index": 0, "item": ["type": "message", "id": message, "role": "assistant", "status": "in_progress", "content": []]]),
            await event("response.content_part.added", ["output_index": 0, "item_id": message, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]])
      else { return }
      for part in parts {
        guard await event("response.output_text.delta", ["output_index": 0, "item_id": message, "content_index": 0, "delta": part, "logprobs": []]) else { return }
      }
      return await wire.disconnected()
    default: return
    }
    guard await event("response.output_item.done", ["output_index": 0, "item": item]) else { return }
    let usage: [String: Any] = ["input_tokens": usage, "output_tokens": 5, "total_tokens": usage + 5,
                                "input_tokens_details": ["cached_tokens": 0], "output_tokens_details": ["reasoning_tokens": 0]]
    _ = await event("response.completed", ["response": base.merging(["status": "completed", "output": [item], "usage": usage]) { $1 }])
  }

  // MARK: Anthropic Messages

  private func messages(_ reply: FakeReply) async {
    func event(_ type: String, _ fields: [String: Any]) async -> Bool {
      await wire.send("event: \(type)\ndata: \(jsonText(fields.merging(["type": type]) { $1 }))\n\n")
    }
    let start: [String: Any] = ["id": "msg_\(id)", "type": "message", "role": "assistant", "model": request.model, "content": [],
                                "stop_reason": NSNull(), "stop_sequence": NSNull(),
                                "usage": ["input_tokens": usage, "output_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]]
    guard await event("message_start", ["message": start]) else { return }
    let stop: String
    switch reply {
    case .say(let text):
      guard await event("content_block_start", ["index": 0, "content_block": ["type": "text", "text": ""]]),
            await event("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": text]]),
            await event("content_block_stop", ["index": 0])
      else { return }
      stop = "end_turn"
    case .call(let name, let input):
      guard await event("content_block_start", ["index": 0, "content_block": ["type": "tool_use", "id": "toolu_\(id)", "name": request.tool(name), "input": [:]]]),
            await event("content_block_delta", ["index": 0, "delta": ["type": "input_json_delta", "partial_json": arguments(input)]]),
            await event("content_block_stop", ["index": 0])
      else { return }
      stop = "tool_use"
    case .stream(let parts):
      guard await event("content_block_start", ["index": 0, "content_block": ["type": "text", "text": ""]]) else { return }
      for part in parts { guard await event("content_block_delta", ["index": 0, "delta": ["type": "text_delta", "text": part]]) else { return } }
      return await wire.disconnected()
    default: return
    }
    guard await event("message_delta", ["delta": ["stop_reason": stop, "stop_sequence": NSNull()], "usage": ["output_tokens": 5]]) else { return }
    _ = await event("message_stop", [:])
  }

  // MARK: 不要流式的请求

  private func whole(_ reply: FakeReply) -> [String: Any] {
    let text: String? = switch reply {
    case .say(let text): text
    case .stream(let parts): parts.joined()
    default: nil
    }
    let call: (name: String, input: String)? = if case .call(let name, let input) = reply { (request.tool(name), arguments(input)) } else { nil }
    switch api {
    case .chat:
      var message: [String: Any] = ["role": "assistant", "content": text.map { $0 as Any } ?? NSNull()]
      if let call { message["tool_calls"] = [["id": "call_\(id)", "type": "function", "function": ["name": call.name, "arguments": call.input]]] }
      return ["id": "chatcmpl-\(id)", "object": "chat.completion", "created": 0, "model": request.model,
              "choices": [["index": 0, "message": message, "finish_reason": call == nil ? "stop" : "tool_calls"]],
              "usage": ["prompt_tokens": usage, "completion_tokens": 5, "total_tokens": usage + 5]]
    case .messages:
      let content: [[String: Any]] = call.map { [["type": "tool_use", "id": "toolu_\(id)", "name": $0.name, "input": (try? JSONSerialization.jsonObject(with: Data($0.input.utf8))) ?? [:]]] }
        ?? [["type": "text", "text": text ?? ""]]
      return ["id": "msg_\(id)", "type": "message", "role": "assistant", "model": request.model, "content": content,
              "stop_reason": call == nil ? "end_turn" : "tool_use", "stop_sequence": NSNull(), "usage": ["input_tokens": usage, "output_tokens": 5]]
    case .responses, .other:
      let item: [String: Any] = call.map { ["type": "function_call", "id": "fc_\(id)", "call_id": "call_\(id)", "name": $0.name, "arguments": $0.input, "status": "completed"] }
        ?? ["type": "message", "id": "msg_\(id)", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text ?? "", "annotations": []]]]
      return ["id": "resp_\(id)", "object": "response", "created_at": 0, "model": request.model, "status": "completed", "output": [item],
              "usage": ["input_tokens": usage, "output_tokens": 5, "total_tokens": usage + 5]]
    }
  }
}
#endif
