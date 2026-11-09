#if os(macOS)
import CueStore
import Foundation

/// 退出靠关标准输入（读到 EOF 正常收尾）；进程退出时等着的请求以 `sessionEnded` 失败，再调 `onClose`。
@MainActor
final class ClaudeStream {
    let process: ChildProcess
    var onMessage: ((JSONValue) -> Void)?
    /// 主会话（`parent_tool_use_id` 为空）正在说的这条回答（`PiDraft`，拼法见 `DraftParts`）；正常说完的留着，不清。
    /// 起点是第一段定稿那一行的 `timestamp`，定稿之前是收到 `message_start` 的时刻（`PiDraft.since`）。
    var onDraft: ((PiDraft?) -> Void)?
    private var speech = DraftParts()
    /// 正在说的文字块的块号（`content_block_start` 给的）；不发增量时没有，定稿接在最后一段后面
    private var openBlock: Int?
    /// 输出读完了（进程退出）；只调一次
    var onClose: (() -> Void)?
    /// 主会话的模型开始回话（流里的 `message_start`）：请求被模型收下了。没登录、模型不可用、额度用完时没有它（`ClaudeDelivery`）
    var onReply: (() -> Void)?
    private let replies = PendingReplies<String, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: PiBridgeError.ackTimeout)
    private var inputClosed = false

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], timing: Timing = .system) async throws {
        process = try await ChildProcess(
            executable, ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"] + arguments,
            directory: directory, environment: environment, placement: .group, input: .pipe, output: .lines, timing: timing)
        let lines = process.output
        Task { [weak self] in
            for await line in lines { self?.received(line) }
            self?.closed()
        }
    }

    var isClosed: Bool { replies.isClosed }

    /// 它开始请求模型（`system/status` 的 `requesting`）：主会话的一轮从这里算起，到 `result` 止。不从 `system/init` 算：
    /// 子代理经 SubagentHandback 交回时同一份结果排进两条，第二条只空跑一轮（`init` 后直接 `result`，`num_turns` 为 0），
    /// 算上就歇下两次（2.1.299 实测，auto 模式下子代理才走这条路）。
    static func requestsModel(_ message: JSONValue) -> Bool {
        message["type"]?.string == "system" && message["subtype"]?.string == "status" && message["status"]?.string == "requesting"
    }

    static func content(text: String, images: [PiImage]) -> JSONValue {
        var content: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        for image in images {
            content.append(["type": "image", "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())]])
        }
        return .array(content)
    }

    /// 写一条。输入已关或进程已退出时抛 `sessionEnded`。
    func write(_ message: JSONValue) throws {
        guard !inputClosed, !isClosed else { throw PiBridgeError.sessionEnded }
        process.write(message.data)
    }

    /// 控制请求，返回回应里的 `response`；Claude Code 回错误抛 `rejected`，超时抛 `ackTimeout`。
    func request(_ body: JSONValue) async throws -> JSONValue {
        let requestID = UUID().uuidString
        return try await replies.request(requestID) {
            try write(["type": "control_request", "request_id": .string(requestID), "request": body])
        }
    }

    /// 换模型，下一次请求模型起生效；Claude Code 先向服务端核对，不认的模型回错误。
    func setModel(_ id: String) async throws {
        _ = try await request(["subtype": "set_model", "model": .string(id)])
    }

    /// 换思考强度（夹到 Claude Code 的档，`ClaudeCode.effort`），返回交出去的档。
    @discardableResult
    func setEffort(_ level: PiThinkingLevel) async throws -> String {
        let effort = ClaudeCode.effort(level)
        _ = try await request(["subtype": "apply_flag_settings", "settings": ["effortLevel": .string(effort)]])
        return effort
    }

    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        process.closeInput()
    }

    private func received(_ line: Data) {
        guard let message = JSONValue.parse(line) else { return }
        switch message["type"]?.string {
        case "control_response": return respond(message)
        case "stream_event": return streamed(message)
        case "system" where message["subtype"]?.string == "init": restart(nil)
        case "result" where message["is_error"]?.bool == true: restart(nil)
        case "assistant" where isMain(message): finished(message)
        default: break
        }
        onMessage?(message)
    }

    private func respond(_ message: JSONValue) {
        let response = message["response"]
        guard let request = response?["request_id"]?.string else { return }
        replies.resolve(request, with: response?["subtype"]?.string == "success"
            ? .success(response?["response"] ?? .object([:]))
            : .failure(PiBridgeError.rejected(response?["error"]?.string ?? "failed")))
    }

    private func isMain(_ message: JSONValue) -> Bool { message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] == .null }

    private func streamed(_ message: JSONValue) {
        guard isMain(message), let event = message["event"] else { return }
        let index = event["index"]?.int
        switch event["type"]?.string {
        case "message_start":
            restart(event["message"]?["id"]?.string, since: .now)
            onReply?()
        case "content_block_start" where event["content_block"]?["type"]?.string == "tool_use":
            restart(speech.message)
        case "content_block_start" where event["content_block"]?["type"]?.string == "text":
            openBlock = index
        case "content_block_delta" where event["delta"]?["type"]?.string == "text_delta":
            guard let text = event["delta"]?["text"]?.string else { return }
            speech.append(text, to: index ?? openBlock ?? 0)
            onDraft?(speech.draft)
        default:
            break
        }
    }

    /// 完整的 `assistant` 行的 `timestamp` 与会话文件里那一行相同。
    private func finished(_ line: JSONValue) {
        let message = line["message"]
        let written = line["timestamp"]?.string.flatMap { try? Date($0, strategy: Self.timestampStyle) }
        let id = message?["id"]?.string
        if id != speech.message { restart(id) }
        for block in message?["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text":
                speech.finish(openBlock ?? speech.lastPart.map { $0 + 1 } ?? 0, with: block["text"]?.string ?? "", at: written)
                openBlock = nil
            case "tool_use": restart(id)
            default: break
            }
        }
        onDraft?(speech.draft)
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private func restart(_ message: String?, since: Date? = nil) {
        speech = DraftParts(message: message, since: since)
        openBlock = nil
        onDraft?(nil)
    }

    private func closed() {
        replies.closeAll(PiBridgeError.sessionEnded)
        onClose?()
    }
}
#endif
