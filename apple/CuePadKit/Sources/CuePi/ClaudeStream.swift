#if os(macOS)
import Foundation

/// 到一个 `claude` 子进程的 stream-json 连接（`--input-format/--output-format stream-json`，与 Agent SDK 同一套线协议）：
/// 后台托管的会话（`ClaudeHostedSession`）与 Cue 的大脑（`ClaudeBrain`）共用。
/// 控制请求（`control_request`）按 `request_id` 配上回应，至多等 `requestTimeout`；正在说的话在这里得出交给 `onDraft`
/// （逐字增量是 `--include-partial-messages` 的 `stream_event`，定稿是每个内容块说完时那一行完整的 `assistant`）；除增量外每行交给 `onMessage`。
/// 退出靠关标准输入（读到 EOF 正常收尾）；进程退出时等着的请求以 `sessionEnded` 失败，再调 `onClose`。
@MainActor
final class ClaudeStream {
    let process: LineProcess
    var onMessage: ((ClaudeJSON) -> Void)?
    /// 主会话（`parent_tool_use_id` 为空）正在说的这条回答（`PiDraft`）变了：只算正文，文字块按换行连接；说到一半的块用 `text_delta` 累积，
    /// 说完的块换成 `assistant` 行里的定稿（不发增量时也照样有全文）。新的一条消息开始（`message_start` 或换了消息 id）、
    /// 转成工具调用（`tool_use` 块）、下一轮开始（`system/init`）、这一轮停下或出错（`result` 的 `is_error`）时清掉，正常说完的留着
    var onDraft: ((PiDraft?) -> Void)?
    private var draft: PiDraft?
    /// 主会话正在说的这条消息：说完的文字块（定稿）与说到一半的那块（增量）
    private var speech = Speech()
    private struct Speech {
        var message: String?
        var finished: [String] = []
        var open = ""
        var text: String { (finished + [open]).filter { !$0.isEmpty }.joined(separator: "\n") }
    }
    /// 输出读完了（进程退出）；只调一次
    var onClose: (() -> Void)?
    private var requests: [String: CheckedContinuation<ClaudeJSON, any Error>] = [:]
    private var inputClosed = false
    /// 输出读完了（进程退出）：之后的请求不再等
    private(set) var isClosed = false

    static let requestTimeout: Duration = .seconds(30)

    /// 启动进程（`arguments` 接在 stream-json 的参数后面），开始读它的输出。
    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
        process = try LineProcess(
            executable: executable,
            arguments: ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"] + arguments,
            directory: directory, environment: environment)
        let lines = process.lines
        Task { [weak self] in
            for await line in lines { self?.received(line) }
            self?.closed()
        }
    }

    /// 一条用户消息的内容：文字在前、图片块在后（空文字不带）。
    static func content(text: String, images: [PiImage]) -> ClaudeJSON {
        var content: [ClaudeJSON] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        for image in images {
            content.append(["type": "image", "source": ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.data.base64EncodedString())]])
        }
        return .array(content)
    }

    /// 写一条。输入已关或进程已退出时抛 `sessionEnded`。
    func write(_ message: ClaudeJSON) throws {
        guard !inputClosed, !isClosed else { throw PiBridgeError.sessionEnded }
        process.write(message.data)
    }

    /// 控制请求，返回回应里的 `response`；Claude Code 回错误抛 `rejected`，超时抛 `ackTimeout`。
    func request(_ body: ClaudeJSON) async throws -> ClaudeJSON {
        guard !isClosed else { throw PiBridgeError.sessionEnded }
        let requestID = UUID().uuidString
        var timeout: Task<Void, Never>?
        defer { timeout?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try write(["type": "control_request", "request_id": .string(requestID), "request": body])
            } catch {
                return continuation.resume(throwing: error)
            }
            requests[requestID] = continuation
            timeout = Task { [weak self] in
                guard (try? await Task.sleep(for: Self.requestTimeout)) != nil else { return }
                self?.requests.removeValue(forKey: requestID)?.resume(throwing: PiBridgeError.ackTimeout)
            }
        }
    }

    /// 关标准输入：它收完手上的就退出（在等确认时也立即退出）。
    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        process.closeInput()
    }

    private func received(_ line: Data) {
        guard let message = ClaudeJSON.parse(line) else { return }
        switch message["type"]?.string {
        case "control_response": return respond(message)
        case "stream_event": return streamed(message)
        case "system" where message["subtype"]?.string == "init": restart(nil)
        case "result" where message["is_error"]?.bool == true: restart(nil)
        case "assistant" where isMain(message): finished(message["message"])
        default: break
        }
        onMessage?(message)
    }

    private func respond(_ message: ClaudeJSON) {
        let response = message["response"]
        guard let request = response?["request_id"]?.string, let waiting = requests.removeValue(forKey: request) else { return }
        if response?["subtype"]?.string == "success" {
            waiting.resume(returning: response?["response"] ?? .object([:]))
        } else {
            waiting.resume(throwing: PiBridgeError.rejected(response?["error"]?.string ?? "failed"))
        }
    }

    private func isMain(_ message: ClaudeJSON) -> Bool { message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] == .null }

    private func streamed(_ message: ClaudeJSON) {
        guard isMain(message), let event = message["event"] else { return }
        switch event["type"]?.string {
        case "message_start":
            restart(event["message"]?["id"]?.string)
        case "content_block_start" where event["content_block"]?["type"]?.string == "tool_use":
            restart(speech.message)
        case "content_block_delta" where event["delta"]?["type"]?.string == "text_delta":
            guard let text = event["delta"]?["text"]?.string else { return }
            speech.open += text
            publish()
        default:
            break
        }
    }

    /// 一个内容块说完了（完整的 `assistant` 行，一行一块）：文字块的定稿换下它的增量，工具调用清掉这条。
    private func finished(_ message: ClaudeJSON?) {
        let id = message?["id"]?.string
        if id != speech.message { restart(id) }
        for block in message?["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text":
                speech.finished.append(block["text"]?.string ?? "")
                speech.open = ""
            case "tool_use": restart(id)
            default: break
            }
        }
        publish()
    }

    /// 重新开始一条（`message` 为它的 id）：清掉正在说的话。
    private func restart(_ message: String?) {
        speech = Speech(message: message)
        publish()
    }

    private func publish() {
        let text = speech.text
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : PiDraft(text: text, since: draft?.since ?? .now)
        guard next != draft else { return }
        draft = next
        onDraft?(next)
    }

    private func closed() {
        isClosed = true
        for waiting in requests.values { waiting.resume(throwing: PiBridgeError.sessionEnded) }
        requests = [:]
        onClose?()
    }
}
#endif
