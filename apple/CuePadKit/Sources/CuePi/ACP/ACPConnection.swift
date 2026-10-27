#if os(macOS)
import CueStore
import Foundation

/// 一条到 ACP Agent 的连接（Agent Client Protocol v1，https://agentclientprotocol.com/protocol/overview ）：JSON-RPC 2.0，
/// 标准输入输出上一行一条。CuePad 是客户端：起 Agent 的 ACP 服务（`<可执行文件> <各家的参数>`，`ACPDialect.arguments`），握手后发请求、
/// 收通知与 Agent 发来的请求（权限确认等）。客户端能力一项不报：文件与终端都由 Agent 自己做。
/// 回应按 id 配给请求（`PendingReplies`）：一般的至多等 `AgentTimeouts.reply`，一轮（`session/prompt`）不限时——这一轮结束它才回。
/// Agent 发来的请求交给 `onRequest`，它不接（返回 false）的回"没有这个方法"，不让对方干等。
@MainActor
final class ACPConnection {
    let process: ChildProcess
    /// 握手的回应：`agentCapabilities`、`authMethods` 与各家放在 `_meta` 里的扩展信息
    private(set) var agent: JSONValue = [:]
    /// 通知（方法、参数）
    var onNotification: ((String, JSONValue) -> Void)?
    /// Agent 发来的请求（方法、参数、请求 id）：接了返回 true，之后用 `respond` 回它
    var onRequest: ((String, JSONValue, JSONValue) -> Bool)?
    /// 连接断了（进程退出）；只调一次
    var onClose: (() -> Void)?
    private var nextID = 0
    private let replies = PendingReplies<Int, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: ACPError.timedOut)
    private var reader: Task<Void, Never>?

    private init(_ process: ChildProcess) {
        self.process = process
        reader = Task { [weak self] in
            for await line in process.output { self?.receive(line) }
            self?.closed()
        }
    }

    /// 起 Agent 的 ACP 服务并握手（`initialize`，协议版本 1）；起不来、握手失败或超时时停掉进程再抛错。
    static func launch(_ executable: URL, _ arguments: [String], environment: [String: String], directory: URL? = nil) async throws -> ACPConnection {
        let process = try await ChildProcess(
            executable, arguments, directory: directory, environment: environment, placement: .group, input: .pipe, output: .lines)
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

    /// 发一个请求，等它的结果；Agent 回错误抛 `server`，连接先断了抛 `closed`，`timed` 时没有及时回应抛 `timedOut`。
    @discardableResult
    func call(_ method: String, _ params: JSONValue, timed: Bool = true) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let message = try await replies.request(id, timed: timed) {
            send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
        if let error = message["error"] { throw ACPError.server(code: error["code"]?.int ?? 0, message: Self.message(of: error)) }
        return message["result"] ?? [:]
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

    /// 错误的原话：`data` 里有具体原因的（字符串，或带 `message` 的对象）用它，否则是 `message`。
    private static func message(of error: JSONValue) -> String {
        error["data"]?.string ?? error["data"]?["message"]?.string ?? error["message"]?.string ?? ""
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
            replies.resolve(id, with: .success(message))
        }
    }

    private func closed() {
        guard !isClosed else { return }
        replies.closeAll(ACPError.closed)
        onClose?()
    }
}

enum ACPError: Error, Equatable {
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
