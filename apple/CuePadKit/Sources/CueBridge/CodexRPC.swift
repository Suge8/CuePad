#if os(macOS)
import CueStore
import Foundation

/// app-server 协议是没有 `jsonrpc` 字段的 JSON-RPC 2.0。服务端请求（审批、提问）只发给订阅了线程的连接：交给 `onRequest`，它不接（返回 false）的回错误，不让对方干等。
@MainActor
final class CodexRPC {
    let pid: Int32
    let process: ChildProcess
    private var nextID = 0
    private let replies = PendingReplies<Int, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: CodexRPCError.timedOut)
    private var reader: Task<Void, Never>?
    var onNotification: ((String, JSONValue) -> Void)?
    /// 服务端请求（方法、请求 id、参数）：接了返回 true，之后用 `respond` 回它
    var onRequest: ((String, JSONValue, JSONValue) -> Bool)?
    /// 一个线程正在说的这条回答（`LiveDraft`，一个 `agentMessage` 项的正文，拼法见 `DraftParts`）；起点是这一项开始（`item/started`）时 Codex 自己的时刻（通知的 `emittedAtMs`，与会话文件同一时钟），落库按这一项的 id 认（`LiveDraft.record`）；正常说完的留着。
    /// 过程中的说明（`phase` 为 commentary）说完就清，不等下一项开始：说明不进对话（`CodexHistory` 只收 final_answer），留着换不下。
    var onDraft: ((_ threadID: String, LiveDraft?) -> Void)?
    private var drafts: [String: DraftParts] = [:]
    /// 只调一次
    var onClose: (() -> Void)?

    private init(_ process: ChildProcess) {
        pid = process.pid
        self.process = process
        reader = Task { [weak self] in
            for await message in process.output { self?.receive(message) }
            self?.closed()
        }
    }

    var isClosed: Bool { replies.isClosed }

    static func input(text: String, images: [MessageImage]) -> [JSONValue] {
        let text: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text), "text_elements": []]]
        return text + images.map { ["type": "image", "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")] }
    }

    /// 握手失败或超时时停掉这个进程再抛错。`spawned` 在进程起来、握手之前调（托管的在这里登记，`HostedProcesses.admit`），抛错时同样停掉。
    static func launch(
        _ executable: URL, arguments: [String] = [], environment: [String: String], directory: URL? = nil, timing: Timing = .system,
        spawned: (ChildProcess) async throws -> Void = { _ in }
    ) async throws -> CodexRPC {
        let process = try await ChildProcess(
            executable, ["app-server", "--listen", "stdio://"] + arguments, directory: directory, environment: environment,
            placement: .group, input: .pipe, output: .lines, timing: timing)
        let rpc = CodexRPC(process)
        do {
            try await spawned(process)
        } catch {
            await process.stop()
            throw error
        }
        try await rpc.handshake()
        return rpc
    }

    /// 握手；失败或超时时停掉进程、等它走完再抛错。
    private func handshake() async throws {
        do {
            try await call("initialize", [
                "clientInfo": ["name": "cuepad", "title": "CuePad", "version": "1"],
                "capabilities": ["experimentalApi": true],
            ])
        } catch {
            process.end()
            await reader?.value
            throw error
        }
        send(["method": "initialized"])
    }

    /// 服务端回错误抛 `server`，连接先断了抛 `closed`，没有及时回应抛 `timedOut`。
    @discardableResult
    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let message = try await replies.request(id) { send(["id": .number(Double(id)), "method": .string(method), "params": params]) }
        if let error = message["error"] {
            throw CodexRPCError.server(code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "")
        }
        return message["result"] ?? .object([:])
    }

    func respond(to id: JSONValue, result: JSONValue) {
        send(["id": id, "result": result])
    }

    /// 关掉并等到进程真的走了：关了输入还不走就 SIGTERM，再不走结束它的进程组（`ChildProcess.stop`）。
    func shutdown() async {
        await process.stop()
        await reader?.value
    }

    private func send(_ message: JSONValue) {
        guard !isClosed else { return }
        process.write(message.data)
    }

    private func receive(_ data: Data) {
        guard let message = JSONValue.parse(data) else { return }
        let method = message["method"]?.string
        if let id = message["id"], let method {
            if onRequest?(method, id, message["params"] ?? .object([:])) != true {
                send(["id": id, "error": ["code": -32000, "message": .string("CuePad 不处理 \(method)")]])
            }
        } else if let method {
            let params = message["params"] ?? .object([:])
            let emitted = message["emittedAtMs"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
            guard !drafted(method, params, emitted: emitted) else { return }
            onNotification?(method, params)
        } else if let id = message["id"]?.int {
            replies.resolve(id, with: .success(message))
        }
    }

    /// 增量本身到此为止（不再交给 `onNotification`），返回 true。
    private func drafted(_ method: String, _ params: JSONValue, emitted: Date?) -> Bool {
        guard let thread = params["threadId"]?.string else { return false }
        switch method {
        case "item/agentMessage/delta":
            guard let item = params["itemId"]?.string, let delta = params["delta"]?.string else { return true }
            update(thread, item: item) { $0.append(delta, to: 0) }
            return true
        case "item/started":
            clearDraft(thread)
            if let item = params["item"], item["type"]?.string == "agentMessage", let id = item["id"]?.string {
                drafts[thread] = Self.parts(thread, item: id, since: emitted)
            }
        case "turn/started":
            clearDraft(thread)
        case "item/completed":
            guard let item = params["item"], item["type"]?.string == "agentMessage" else { break }
            if item["phase"]?.string == "commentary" {
                clearDraft(thread)
            } else if let id = item["id"]?.string, let text = item["text"]?.string {
                update(thread, item: id) { $0.finish(0, with: text) }
            }
        case "turn/completed" where params["turn"]?["status"]?.string != "completed":
            clearDraft(thread)
        default:
            break
        }
        return false
    }

    private func update(_ thread: String, item: String, _ edit: (inout DraftParts) -> Void) {
        var parts = drafts[thread].flatMap { $0.message == item ? $0 : nil } ?? Self.parts(thread, item: item)
        edit(&parts)
        drafts[thread] = parts
        onDraft?(thread, parts.draft)
    }

    private static func parts(_ thread: String, item: String, since: Date? = nil) -> DraftParts {
        DraftParts(message: item, since: since, record: ChatMessage.recordID(sessionID: thread, entryID: item))
    }

    private func clearDraft(_ thread: String) {
        drafts[thread] = nil
        onDraft?(thread, nil)
    }

    private func closed() {
        guard !isClosed else { return }
        process.closeInput()
        replies.closeAll(CodexRPCError.closed)
        onClose?()
    }
}

enum CodexRPCError: Error, Equatable {
    case server(code: Int, message: String)
    case closed
    case timedOut
}

extension CodexRPCError: ShownError {
    var shown: String.LocalizationValue {
        switch self {
        case .server(_, let message): "Codex 拒绝了：\(message)"
        case .closed: "Codex 的 app-server 没有回应就退出了"
        case .timedOut: "Codex 的 app-server 没有及时回应"
        }
    }
}

#endif
