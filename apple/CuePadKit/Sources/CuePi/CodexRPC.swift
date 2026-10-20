#if os(macOS)
import Darwin
import Foundation

/// 一条到 Codex app-server 的 JSON-RPC 连接（app-server 协议：没有 `jsonrpc` 字段的 JSON-RPC 2.0）。两种传输：
/// CuePad 自己起的 `codex app-server --listen stdio://`（一行一条 JSON），与常驻服务的控制 socket（unix socket 上的 WebSocket，一帧一条）。
/// 回应按 id 配给请求（`PendingReplies`，至多等 `AgentTimeouts.reply`）；通知交给 `onNotification`，其中回答的逐字增量
/// （`item/agentMessage/delta`）在这里累积成正在说的话交给 `onDraft`，回答项说完时换成它的全文。服务端请求（审批、提问）只发给订阅了线程的
/// 连接：交给 `onRequest`，它不接（返回 false）的回错误，不让对方干等。
@MainActor
final class CodexRPC {
    /// 对端进程：自己起的 app-server，或控制 socket 那头的常驻服务
    let pid: Int32
    private let transport: Transport
    private var nextID = 0
    private let replies = PendingReplies<Int, JSONValue>(timeout: AgentTimeouts.reply, timeoutError: CodexRPCError.timedOut)
    private var reader: Task<Void, Never>?
    var onNotification: ((String, JSONValue) -> Void)?
    /// 服务端请求（方法、请求 id、参数）：接了返回 true，之后用 `respond` 回它
    var onRequest: ((String, JSONValue, JSONValue) -> Bool)?
    /// 一个线程正在说的这条回答（`PiDraft`，一个 `agentMessage` 项的正文，拼法见 `DraftParts`）：随增量更新，这一项说完（`item/completed`）时换成它带的全文
    /// （不发增量时也照样有）；起点是这一项开始（`item/started`）时 Codex 自己的时刻（通知的 `emittedAtMs`，与会话文件同一时钟）；过程中的说明（`phase` 为 commentary）说完、
    /// 下一项开始（转成工具调用、思考等）、下一轮开始、这一轮停下或失败（`turn/completed` 不是 completed）时清掉，正常说完的留着。
    /// 说明说完就清，不等工具那一项开始：两者之间 Codex 先跑 PreToolUse 钩子，状态已切到工具，草稿再留着就和工具那一行叠着；
    /// 说明也不进对话（`CodexHistory` 只收 final_answer），留着换不下。只有订阅了线程的连接（自己起的进程）收得到增量
    var onDraft: ((_ threadID: String, PiDraft?) -> Void)?
    /// 每个线程正在说的那一项（`DraftParts` 的 `message` 是项 id，整项一段）
    private var drafts: [String: DraftParts] = [:]
    /// 连接断了（进程退出、常驻服务退出）；只调一次
    var onClose: (() -> Void)?

    private init(pid: Int32, transport: Transport, messages: AsyncStream<Data>) {
        self.pid = pid
        self.transport = transport
        reader = Task { [weak self] in
            for await message in messages { self?.receive(message) }
            self?.closed()
        }
    }

    var isClosed: Bool { replies.isClosed }

    // MARK: 建立

    /// 一条用户输入（`UserInput`）：文字在前（空文字不带）、图片以 data URL 在后。
    static func input(text: String, images: [PiImage]) -> [JSONValue] {
        let text: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text), "text_elements": []]]
        return text + images.map { ["type": "image", "url": .string("data:\($0.mimeType);base64,\($0.data.base64EncodedString())")] }
    }

    /// 起一个 `codex app-server --listen stdio://`（`arguments` 接在后面，如 `-c` 覆盖配置）并完成握手；握手失败或超时时停掉这个进程再抛错。
    static func launch(
        _ executable: URL, arguments: [String] = [], environment: [String: String], directory: URL? = nil
    ) async throws -> CodexRPC {
        let process = try ChildProcess(
            executable, ["app-server", "--listen", "stdio://"] + arguments, directory: directory, environment: environment,
            placement: .group, input: .pipe, output: .lines)
        let rpc = CodexRPC(pid: process.pid, transport: .stdio(process), messages: process.output)
        try await rpc.handshake()
        return rpc
    }

    /// 自己起的进程（控制 socket 为 nil）：等它退出、取退出原因，或不经主线程停掉它。
    var process: ChildProcess? {
        if case .stdio(let process) = transport { process } else { nil }
    }

    /// 连上常驻服务的控制 socket 并完成握手；socket 不在、连不上或没有及时握手抛错。
    static func connect(socket path: String) async throws -> CodexRPC {
        let (socket, leftover) = try await WebSocket.open(path)
        let (messages, continuation) = AsyncStream<Data>.makeStream()
        socket.read(after: leftover, into: continuation)
        let rpc = CodexRPC(pid: socket.peer, transport: .socket(socket), messages: messages)
        try await rpc.handshake()
        return rpc
    }

    /// 握手；失败或超时时停掉对端、等它走完再抛错。
    private func handshake() async throws {
        do {
            try await call("initialize", [
                "clientInfo": ["name": "cuepad", "title": "CuePad", "version": "1"],
                "capabilities": ["experimentalApi": true],
            ])
        } catch {
            transport.terminate()
            await reader?.value
            throw error
        }
        send(["method": "initialized"])
    }

    // MARK: 收发

    /// 发一个请求，等它的回应（结果的 `result`）；服务端回错误抛 `server`，连接先断了抛 `closed`，没有及时回应抛 `timedOut`。
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

    /// 关掉：自己起的进程关标准输入（app-server 读到 EOF 就收尾退出），控制 socket 直接断开。
    func close() {
        transport.close()
    }

    /// 停掉对端、不等：自己起的进程 SIGTERM（不等它读到 EOF 收尾，用于它卡住时），控制 socket 断开。
    func terminate() {
        transport.terminate()
    }

    /// 关掉并等到对端真的走了：自己起的进程关了输入还不走就 SIGTERM，再不走结束它的进程组（`ChildProcess.stop`）。
    func shutdown() async {
        if case .stdio(let process) = transport { await process.stop() } else { close() }
        await reader?.value
    }

    private func send(_ message: JSONValue) {
        guard !isClosed else { return }
        transport.write(message.data)
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

    /// 改正在说的话；增量本身到此为止（不再交给 `onNotification`），返回 true。
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
                drafts[thread] = DraftParts(message: id, since: emitted)
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

    /// 改一个线程正在说的那一项（换了项就重新开始）。
    private func update(_ thread: String, item: String, _ edit: (inout DraftParts) -> Void) {
        var parts = drafts[thread].flatMap { $0.message == item ? $0 : nil } ?? DraftParts(message: item)
        edit(&parts)
        drafts[thread] = parts
        onDraft?(thread, parts.draft)
    }

    private func clearDraft(_ thread: String) {
        drafts[thread] = nil
        onDraft?(thread, nil)
    }

    private func closed() {
        guard !isClosed else { return }
        transport.close()
        replies.closeAll(CodexRPCError.closed)
        onClose?()
    }

    // MARK: 传输

    private enum Transport {
        case stdio(ChildProcess)
        case socket(WebSocket)

        func write(_ data: Data) {
            switch self {
            case .stdio(let process): process.write(data)
            case .socket(let socket): socket.send(data)
            }
        }

        func close() {
            switch self {
            case .stdio(let process): process.closeInput()
            case .socket(let socket): socket.close()
            }
        }

        func terminate() {
            switch self {
            case .stdio(let process): process.end()
            case .socket(let socket): socket.close()
            }
        }
    }
}

enum CodexRPCError: Error, Equatable {
    case server(code: Int, message: String)
    case closed
    case unreachable
    /// 对端没有及时回应（握手时已停掉它）
    case timedOut
}

extension CodexRPCError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .server(_, let message): "Codex 拒绝了：\(message)"
        case .closed: "Codex 的 app-server 没有回应就退出了"
        case .unreachable: "连不上 Codex 的常驻服务"
        case .timedOut: "Codex 的 app-server 没有及时回应"
        }
    }
}

/// unix socket 上的 WebSocket 客户端（RFC 6455 的最小子集：文本帧、分片、ping/pong、关闭）。客户端发的帧要加掩码。
/// 描述符的写入与关闭都在 `queue` 上，`open` 只在那里读写：关掉之后排队的写入不会落到被系统复用的描述符上。
/// 否决 `NWConnection` + `NWProtocolWebSocket`：要拿对端进程号（`LOCAL_PEERPID`，会话按承载进程认）与校验对端属主，它都不给。
private final class WebSocket: @unchecked Sendable {
    let fd: Int32
    /// 对端进程号
    let peer: Int32
    private let queue = DispatchQueue(label: "cuepad.codex-ws")
    private var open = true

    private init(fd: Int32, peer: Int32) {
        self.fd = fd
        self.peer = peer
    }

    /// 连上 unix socket、做 WebSocket 握手（本地 socket，同步做完，至多等 `AgentTimeouts.reply`），返回连接与握手后多读到的字节。
    @concurrent static func open(_ path: String) async throws -> (WebSocket, Data) {
        let fd: Int32
        do { fd = try UnixSocket.connect(path) } catch { throw CodexRPCError.unreachable }
        guard UnixSocket.peerIsOwner(fd) else { Darwin.close(fd); throw CodexRPCError.unreachable }
        UnixSocket.setReadTimeout(fd, AgentTimeouts.reply)
        defer { UnixSocket.setReadTimeout(fd, nil) }
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard writeAll(fd, Data(request.utf8)) else { Darwin.close(fd); throw CodexRPCError.unreachable }
        var received = Data()
        let buffer = ReadBuffer()
        let end = Data("\r\n\r\n".utf8)
        while received.range(of: end) == nil {
            guard let chunk = buffer.read(from: fd) else { Darwin.close(fd); throw CodexRPCError.unreachable }
            received.append(chunk)
        }
        let headerEnd = received.range(of: end)!
        guard String(decoding: received[..<headerEnd.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 101") else {
            Darwin.close(fd)
            throw CodexRPCError.unreachable
        }
        return (WebSocket(fd: fd, peer: UnixSocket.peerPID(fd)), Data(received[headerEnd.upperBound...]))
    }

    func send(_ payload: Data, opcode: UInt8 = 0x1) {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((count >> ($0 * 8)) & 0xFF) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        let bytes = frame
        queue.async { [self] in
            if open { writeAll(fd, bytes) }
        }
    }

    func close() {
        queue.async { [self] in
            if open { shutdown(fd, SHUT_RDWR) }
        }
    }

    /// 读事件读帧到连接断开；断开时才释放描述符（读是它最后的使用者）。
    func read(after leftover: Data, into continuation: AsyncStream<Data>.Continuation) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let buffer = ReadBuffer()
        let frames = Frames(pending: leftover)
        let drain: @Sendable () -> Bool = { [self] in
            while let frame = Self.frame(in: &frames.pending) {
                switch frame.opcode {
                case 0x0, 0x1, 0x2:
                    frames.message.append(frame.payload)
                    if frame.final {
                        continuation.yield(frames.message)
                        frames.message = Data()
                    }
                case 0x8: return false
                case 0x9: send(frame.payload, opcode: 0xA)
                default: break
                }
            }
            return true
        }
        source.setEventHandler { [self] in
            guard let chunk = buffer.read(from: fd) else { return source.cancel() }
            frames.pending.append(chunk)
            if !drain() { source.cancel() }
        }
        source.setCancelHandler { [self] in
            continuation.finish()
            open = false
            Darwin.close(fd)
        }
        if drain() { source.resume() } else { source.resume(); source.cancel() }
    }

    /// 读到一半的帧与消息；只在 `queue` 上用
    private final class Frames: @unchecked Sendable {
        var pending: Data
        var message = Data()
        init(pending: Data) { self.pending = pending }
    }

    /// 从缓冲头上取出一个完整的帧（服务端的帧不带掩码）；不够一帧为 nil。
    private static func frame(in buffer: inout Data) -> (final: Bool, opcode: UInt8, payload: Data)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let masked = bytes[1] & 0x80 != 0
        let maskOffset = offset
        if masked { offset += 4 }
        guard buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex
        var payload = Data(buffer[(start + offset)..<(start + offset + length)])
        if masked {
            let mask = [UInt8](buffer[(start + maskOffset)..<(start + maskOffset + 4)])
            payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        buffer.removeSubrange(start..<(start + offset + length))
        return (bytes[0] & 0x80 != 0, bytes[0] & 0x0F, payload)
    }
}
#endif
