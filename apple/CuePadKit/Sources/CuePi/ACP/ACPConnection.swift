#if os(macOS)
import CueStore
import Foundation

/// 一条到 ACP Agent 的连接（Agent Client Protocol v1，https://agentclientprotocol.com/protocol/overview ）：JSON-RPC 2.0，
/// 标准输入输出上一行一条。CuePad 是客户端：起 Agent 的 ACP 服务（`<可执行文件> <各家的参数>`，`ACPDialect.arguments`），握手后发请求、
/// 收通知与 Agent 发来的请求（权限确认等）。客户端能力一项不报：文件与终端都由 Agent 自己做。
/// 回应按 id 配给请求（`PendingReplies`）：一般的至多等 `AgentTimeouts.reply`；一轮（`session/prompt`）这一轮结束它才回，不限时，
/// 回应在读到它的那一行当场交出（`request(_:_:reply:)`），与前后的通知同一先后。
/// Agent 发来的请求交给 `onRequest`，它不接（返回 false）的回"没有这个方法"，不让对方干等。
@MainActor
final class ACPConnection {
    let process: ChildProcess
    /// 握手的回应：`agentCapabilities`、`authMethods` 与各家放在 `_meta` 里的扩展信息
    private(set) var agent: JSONValue = [:]
    var onNotification: ((String, JSONValue) -> Void)?
    /// Agent 发来的请求（方法、参数、请求 id）：接了返回 true，之后用 `respond` 回它
    var onRequest: ((String, JSONValue, JSONValue) -> Bool)?
    /// 连接断了（进程退出）；只调一次
    var onClose: (() -> Void)?
    private var nextID = 0
    private let replies = PendingReplies<Int, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: ACPError.timedOut)
    /// `request(_:_:reply:)` 发出、等回应的
    private var inOrder: [Int: (Result<JSONValue, ACPError>) -> Void] = [:]
    private var reader: Task<Void, Never>?

    private init(_ process: ChildProcess) {
        self.process = process
        reader = Task { [weak self] in
            for await line in process.output { self?.receive(line) }
            self?.closed()
        }
    }

    /// 起 Agent 的 ACP 服务并握手（`initialize`，协议版本 1）；起不来、握手失败或超时时停掉进程再抛错。`timing` 交给进程（`ChildProcess`）。
    static func launch(
        _ executable: URL, _ arguments: [String], environment: [String: String], directory: URL? = nil, timing: Timing = .system
    ) async throws -> ACPConnection {
        let process = try await ChildProcess(
            executable, arguments, directory: directory, environment: environment, placement: .group, input: .pipe, output: .lines, timing: timing)
        let connection = ACPConnection(process)
        do {
            connection.agent = try await connection.call("initialize", [
                "protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "cuepad", "title": "CuePad", "version": "1"],
            ])
        } catch {
            await connection.shutdown()
            throw error
        }
        return connection
    }

    var isClosed: Bool { replies.isClosed }

    /// 发一个请求，等它的结果；Agent 回错误抛 `server`，连接先断了抛 `closed`，没有及时回应抛 `timedOut`。
    @discardableResult
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let message = try await replies.request(id) {
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
        if let error = Self.error(in: message) { throw error }
        return message["result"] ?? [:]
    }

    /// 发一个不限时的请求，回应在读到它的那一行当场交给 `reply`：排在之前读到的通知之后、之后的之前（`call` 要等调用方被叫醒，
    /// 那之前同一批读到的通知已先处理了）。Agent 回错误交 `server`，连接先断了交 `closed`。
    func request(_ method: String, _ params: JSONValue, reply: @escaping (Result<JSONValue, ACPError>) -> Void) {
        guard !isClosed else { return reply(.failure(.closed)) }
        nextID += 1
        inOrder[nextID] = reply
        send(["jsonrpc": "2.0", "id": .number(Double(nextID)), "method": .string(method), "params": params])
    }

    func notify(_ method: String, _ params: JSONValue) {
        send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func respond(to id: JSONValue, result: JSONValue) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// 停掉进程并等它走完：先关标准输入请它收尾，不走再 SIGTERM，还不走结束整个进程组（`ChildProcess.stop`）。
    func shutdown() async {
        await process.stop()
        await reader?.value
    }

    /// 回应里的错误：原话是 `data` 里的具体原因（字符串，或带 `message` 的对象），没有就是 `message`。
    private static func error(in message: JSONValue) -> ACPError? {
        guard let error = message["error"] else { return nil }
        let text = error["data"]?.string ?? error["data"]?["message"]?.string ?? error["message"]?.string ?? ""
        return .server(code: error["code"]?.int ?? 0, message: text)
    }

    private func send(_ message: JSONValue) {
        guard !isClosed else { return }
        process.write(message.data)
    }

    private func receive(_ data: Data) {
        guard let message = JSONValue.parse(data) else { return }
        if let method = message["method"]?.string {
            let params = message["params"] ?? [:]
            guard let id = message["id"] else {
                onNotification?(method, params)
                return
            }
            if onRequest?(method, params, id) != true {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("CuePad 不处理 \(method)")]])
            }
        } else if let id = message["id"]?.int {
            if let reply = inOrder.removeValue(forKey: id) {
                reply(Self.error(in: message).map { .failure($0) } ?? .success(message["result"] ?? [:]))
            } else {
                replies.resolve(id, with: .success(message))
            }
        }
    }

    private func closed() {
        guard !isClosed else { return }
        replies.closeAll(ACPError.closed)
        let waiting = inOrder.values
        inOrder = [:]
        for reply in waiting { reply(.failure(.closed)) }
        onClose?()
    }
}

enum ACPError: Error {
    case server(code: Int, message: String)
    case closed
    /// Agent 没有及时回应（握手时已停掉它）
    case timedOut

    /// JSON-RPC 的"参数不对"（ACP 里换到不存在的模型、强度时回它）
    static let invalidParams = -32602
}

extension ACPError: ShownError {
    var shown: String.LocalizationValue {
        switch self {
        case .server(_, let message): "Agent 拒绝了：\(message)"
        case .closed: "Agent 没有回应就退出了"
        case .timedOut: "Agent 没有及时回应"
        }
    }
}
#endif
