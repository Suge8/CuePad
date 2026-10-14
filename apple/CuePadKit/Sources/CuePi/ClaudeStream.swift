#if os(macOS)
import Foundation

/// 到一个 `claude` 子进程的 stream-json 连接（`--input-format/--output-format stream-json`，与 Agent SDK 同一套线协议）：
/// 后台托管的会话（`ClaudeHostedSession`）与 Cue 的大脑（`ClaudeBrain`）共用。
/// 控制请求（`control_request`）按 `request_id` 配上回应（`PendingReplies`）；其余每行交给 `onMessage`。
/// 退出靠关标准输入（读到 EOF 正常收尾）；进程退出时等着的请求以 `sessionEnded` 失败，再调 `onClose`。
@MainActor
final class ClaudeStream {
    let process: ChildProcess
    var onMessage: ((JSONValue) -> Void)?
    /// 输出读完了（进程退出）；只调一次
    var onClose: (() -> Void)?
    private let replies = PendingReplies<String, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: PiBridgeError.ackTimeout)
    private var inputClosed = false

    /// 启动进程（`arguments` 接在 stream-json 的参数后面），开始读它的输出。
    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
        process = try ChildProcess(
            executable, ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose"] + arguments,
            directory: directory, environment: environment, placement: .group, input: .pipe, output: .lines)
        let lines = process.output
        Task { [weak self] in
            for await line in lines { self?.received(line) }
            self?.closed()
        }
    }

    /// 输出读完了（进程退出）：之后的请求不再等
    var isClosed: Bool { replies.isClosed }

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

    /// 关标准输入：它收完手上的就退出（在等确认时也立即退出）。
    func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        process.closeInput()
    }

    private func received(_ line: Data) {
        guard let message = JSONValue.parse(line) else { return }
        guard message["type"]?.string == "control_response" else { return onMessage?(message) ?? () }
        let response = message["response"]
        guard let request = response?["request_id"]?.string else { return }
        replies.resolve(request, with: response?["subtype"]?.string == "success"
            ? .success(response?["response"] ?? .object([:]))
            : .failure(PiBridgeError.rejected(response?["error"]?.string ?? "failed")))
    }

    private func closed() {
        replies.closeAll(PiBridgeError.sessionEnded)
        onClose?()
    }
}
#endif
